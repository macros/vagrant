require "pathname"

require "vagrant"
require "vagrant/config/v2/util"

require File.expand_path("../vm_provider", __FILE__)
require File.expand_path("../vm_provisioner", __FILE__)
require File.expand_path("../vm_subvm", __FILE__)

module VagrantPlugins
  module Kernel_V2
    class VMConfig < Vagrant.plugin("2", :config)
      DEFAULT_VM_NAME = :default

      attr_accessor :base_mac
      attr_accessor :box
      attr_accessor :box_url
      attr_accessor :graceful_halt_retry_count
      attr_accessor :graceful_halt_retry_interval
      attr_accessor :guest
      attr_accessor :host_name
      attr_accessor :usable_port_range
      attr_reader :forwarded_ports
      attr_reader :synced_folders
      attr_reader :networks
      attr_reader :providers
      attr_reader :provisioners

      def initialize
        @forwarded_ports              = []
        @graceful_halt_retry_count    = UNSET_VALUE
        @graceful_halt_retry_interval = UNSET_VALUE
        @synced_folders               = {}
        @networks                     = []
        @provisioners                 = []

        # The providers hash defaults any key to a provider object
        @providers = Hash.new do |hash, key|
          hash[key] = VagrantConfigProvider.new(key, nil)
        end
      end

      # Custom merge method since some keys here are merged differently.
      def merge(other)
        result = super
        result.instance_variable_set(:@forwarded_ports, @forwarded_ports + other.forwarded_ports)
        result.instance_variable_set(:@synced_folders, @synced_folders.merge(other.synced_folders))
        result.instance_variable_set(:@networks, @networks + other.networks)
        result.instance_variable_set(:@provisioners, @provisioners + other.provisioners)
        result
      end

      # Defines a synced folder pair. This pair of folders will be synced
      # to/from the machine. Note that if the machine you're using doesn't
      # support multi-directional syncing (perhaps an rsync backed synced
      # folder) then the host is always synced to the guest but guest data
      # may not be synced back to the host.
      #
      # @param [String] hostpath Path to the host folder to share. If this
      #   is a relative path, it is relative to the location of the
      #   Vagrantfile.
      # @param [String] guestpath Path on the guest to mount the shared
      #   folder.
      # @param [Hash] options Additional options.
      def synced_folder(hostpath, guestpath, options=nil)
        options ||= {}
        options[:id] ||= guestpath
        options[:guestpath] = guestpath
        options[:hostpath]  = hostpath

        @synced_folders[options[:id]] = options
      end

      # Define a way to access the machine via a network. This exposes a
      # high-level abstraction for networking that may not directly map
      # 1-to-1 for every provider. For example, AWS has no equivalent to
      # "port forwarding." But most providers will attempt to implement this
      # in a way that behaves similarly.
      #
      # `type` can be one of:
      #
      #   * `:forwarded_port` - A port that is accessible via localhost
      #     that forwards into the machine.
      #   * `:private_network` - The machine gets an IP that is not directly
      #     publicly accessible, but ideally accessible from this machine.
      #   * `:public_network` - The machine gets an IP on a shared network.
      #
      # @param [Symbol] type Type of network
      def network(type, *args)
        @networks << [type, args]
      end

      # Configures a provider for this VM.
      #
      # @param [Symbol] name The name of the provider.
      def provider(name, &block)
        # TODO: Error if a provider is defined multiple times.
        @providers[name] = VagrantConfigProvider.new(name, block)
      end

      def provision(name, options=nil, &block)
        @provisioners << VagrantConfigProvisioner.new(name, options, &block)
      end

      def defined_vms
        @defined_vms ||= {}
      end

      # This returns the keys of the sub-vms in the order they were
      # defined.
      def defined_vm_keys
        @defined_vm_keys ||= []
      end

      def define(name, options=nil, &block)
        name = name.to_sym
        options ||= {}
        options[:config_version] ||= "2"

        # Add the name to the array of VM keys. This array is used to
        # preserve the order in which VMs are defined.
        defined_vm_keys << name

        # Add the SubVM to the hash of defined VMs
        if !defined_vms[name]
          defined_vms[name] ||= VagrantConfigSubVM.new
        end

        defined_vms[name].options.merge!(options)
        defined_vms[name].config_procs << [options[:config_version], block] if block
      end

      def finalize!
        # If we haven't defined a single VM, then we need to define a
        # default VM which just inherits the rest of the configuration.
        define(DEFAULT_VM_NAME) if defined_vm_keys.empty?
      end

      def validate(machine)
        errors = []
        errors << I18n.t("vagrant.config.vm.box_missing") if !box
        errors << I18n.t("vagrant.config.vm.box_not_found", :name => box) if \
          box && !box_url && !machine.box

        @synced_folders.each do |id, options|
          hostpath = Pathname.new(options[:hostpath]).expand_path(machine.env.root_path)

          if !hostpath.directory? && !options[:create]
            errors << I18n.t("vagrant.config.vm.shared_folder_hostpath_missing",
                             :path => options[:hostpath])
          end

          if options[:nfs] && (options[:owner] || options[:group])
            # Owner/group don't work with NFS
            errors << I18n.t("vagrant.config.vm.shared_folder_nfs_owner_group",
                             :path => options[:hostpath])
          end
        end

        # We're done with VM level errors so prepare the section
        errors = { "vm" => errors }

        # Validate only the _active_ provider
        if machine.provider_config
          provider_errors = machine.provider_config.validate(machine)
          if provider_errors
            errors = Vagrant::Config::V2::Util.merge_errors(errors, provider_errors)
          end
        end

        # Validate provisioners
        @provisioners.each do |vm_provisioner|
          if vm_provisioner.config
            provisioner_errors = vm_provisioner.config.validate(machine)
            if provisioner_errors
              errors = Vagrant::Config::V2::Util.merge_errors(errors, provisioner_errors)
            end
          end
        end

        errors
      end
    end
  end
end
