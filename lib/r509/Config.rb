require 'yaml'
require 'openssl'
require 'r509/Exceptions'
require 'r509/io_helpers'
require 'fileutils'
require 'pathname'

module R509
    # Provides access to configuration profiles
    class ConfigProfile
        attr_reader :basic_constraints, :key_usage, :extended_key_usage,
          :certificate_policies

        # @option [String] :basic_constraints
        # @option [Array] :key_usage
        # @option [Array] :extended_key_usage
        # @option [Array] :certificate_policies
        def initialize(opts = {})
          @basic_constraints = opts[:basic_constraints]
          @key_usage = opts[:key_usage]
          @extended_key_usage = opts[:extended_key_usage]
          @certificate_policies = opts[:certificate_policies]
        end
    end

    # Stores a configuration for our CA.
    class Config
        include R509::IOHelpers
        extend R509::IOHelpers
        attr_accessor :ca_cert, :crl_validity_hours, :message_digest,
          :cdp_location, :crl_start_skew_seconds, :ocsp_location, :ocsp_chain,
          :ocsp_start_skew_seconds, :ocsp_validity_hours, :crl_number_file, :crl_list_file

        # @option opts [R509::Cert] :ca_cert Cert+Key pair
        # @option opts [Integer] :crl_validity_hours (168) The number of hours that
        #  a CRL will be valid. Defaults to 7 days.
        # @option opts [Hash<String, ConfigProfile>] :profiles
        # @option opts [String] :message_digest (SHA1) The hashing algorithm to use.
        # @option opts [String] :cdp_location
        # @option opts [String] :ocsp_location
        # @option opts [String] :crl_number_file The file that we will save
        #  the CRL numbers to. defaults to a StringIO object if not provided
        # @option opts [String] :crl_list_file The file that we will save
        #  the CRL list data to. defaults to a StringIO object if not provided
        # @option opts [R509::Cert] :ocsp_cert An optional cert+key pair
        # OCSP signing delegate
        # @option opts [Array<OpenSSL::X509::Certificate>] :ocsp_chain An optional array
        # that constitutes the chain to attach to an OCSP response
        #
        def initialize(opts = {} )
            if not opts.has_key?(:ca_cert) then
                raise ArgumentError, 'Config object requires that you pass :ca_cert'
            end

            @ca_cert = opts[:ca_cert]

            if not @ca_cert.kind_of?(R509::Cert) then
                raise ArgumentError, ':ca_cert must be of type R509::Cert'
            end
            if not @ca_cert.has_private_key?
                raise ArgumentError, ':ca_cert object must contain a private key, not just a certificate'
            end

            #ocsp data
            if opts.has_key?(:ocsp_cert) and not opts[:ocsp_cert].kind_of(R509::Cert) then
                raise ArgumentError, ':ocsp_cert, if provided, must be of type R509::Cert'
            end
            if opts.has_key?(:ocsp_cert) and not opts[:ocsp_cert].has_private_key?
                raise ArgumentError, ':ocsp_cert must contain a private key, not just a certificate'
            end
            @ocsp_cert = opts[:ocsp_cert]
            @ocsp_location = opts[:ocsp_location]
            @ocsp_chain = opts[:ocsp_chain] if opts[:ocsp_chain].kind_of?(Array)
            @ocsp_validity_hours = opts[:ocsp_validity_hours] || 168
            @ocsp_start_skew_seconds = opts[:ocsp_start_skew_seconds] || 3600

            @crl_validity_hours = opts[:crl_validity_hours] || 168
            @crl_start_skew_seconds = opts[:crl_start_skew_seconds] || 3600
            @crl_number_file = opts[:crl_number_file] || nil
            @crl_list_file = opts[:crl_list_file] || nil
            @cdp_location = opts[:cdp_location]
            @message_digest = opts[:message_digest] || "SHA1"



            @profiles = {}
                if opts[:profiles]
                opts[:profiles].each_pair do |name, prof|
                  set_profile(name, prof)
                end
            end

        end

        # @return [R509::Cert] either a custom OCSP cert or the ca_cert
        def ocsp_cert
            if @ocsp_cert.nil? then @ca_cert else @ocsp_cert end
        end

        # @param [String] name The name of the profile
        # @param [ConfigProfile] prof The profile configuration
        def set_profile(name, prof)
            unless prof.is_a?(ConfigProfile)
                raise TypeError, "profile is supposed to be a R509::ConfigProfile"
            end
            @profiles[name] = prof
        end

        # @param [String] prof
        # @return [ConfigProfile] The config profile.
        def profile(prof)
            if !@profiles.has_key?(prof)
                raise R509Error, "unknown profile '#{prof}'"
            end
            @profiles[prof]
        end

        # @return [Integer] The number of profiles
        def num_profiles
          @profiles.count
        end


        ######### Class Methods ##########

        # Load the configuration from a data hash. The same type that might be
        # used when loading from a YAML file.
        # @param [Hash] conf A hash containing all the configuration options
        # @option opts [String] :ca_root_path The root path for the CA. Defaults to
        #  the current working directory.
        def self.load_from_hash(conf, opts = {})
            if conf.nil?
                raise ArgumentError, "conf not found"
            end
            unless conf.kind_of?(::Hash)
                raise ArgumentError, "conf must be a Hash"
            end

            # Duplicate the hash since we will be destroying parts of it.
            conf = conf.dup

            ca_root_path = Pathname.new(opts[:ca_root_path] || FileUtils.getwd)

            unless File.directory?(ca_root_path)
                raise R509Error, "ca_root_path is not a directory: #{ca_root_path}"
            end

            ca_cert_hash = conf.delete('ca_cert')
            ca_cert_file = ca_root_path + ca_cert_hash['cert']
            ca_key_file = ca_root_path + ca_cert_hash['key']
            ca_cert = R509::Cert.new(
                :cert => read_data(ca_cert_file),
                :key => read_data(ca_key_file)
            )

            opts = {
                :ca_cert => ca_cert,
                :crl_validity_hours => conf.delete('crl_validity_hours'),
                :ocsp_location => conf.delete('ocsp_location'),
                :cdp_location => conf.delete('cdp_location'),
                :message_digest => conf.delete('message_digest'),
            }

            if conf.has_key?("crl_list")
                opts[:crl_list_file] = (ca_root_path + conf.delete('crl_list')).to_s
            end

            if conf.has_key?("crl_number")
                opts[:crl_number_file] = (ca_root_path + conf.delete('crl_number')).to_s
            end


            # The remaining keys should all be profiles :)
            profs = {}
            conf.keys.each do |profile|
                data = conf.delete(profile)
                profs[profile] = ConfigProfile.new(:key_usage => data["key_usage"],
                                                   :extended_key_usage => data["extended_key_usage"],
                                                   :basic_constraints => data["basic_constraints"],
                                                   :certificate_policies => data["certificate_policies"])
            end
            opts[:profiles] = profs

            # Create the instance.
            self.new(opts)
        end

        # Loads the named configuration config from a yaml file.
        # @param [String] conf_name The name of the config within the file. Note
        #  that a single yaml file can contain more than one configuration.
        # @param [String] yaml_file The filename to load yaml config data from.
        def self.load_yaml(conf_name, yaml_file, opts = {})
            conf = YAML.load_file(yaml_file)
            self.load_from_hash(conf[conf_name], opts)
        end

        # Loads the named configuration config from a yaml string.
        # @param [String] conf_name The name of the config within the file. Note
        #  that a single yaml file can contain more than one configuration.
        # @param [String] yaml_file The filename to load yaml config data from.
        def self.from_yaml(conf_name, yaml_data, opts = {})
            conf = YAML.load(yaml_data)
            self.load_from_hash(conf[conf_name], opts)
        end
    end
end
