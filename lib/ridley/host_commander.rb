require 'socket'
require 'timeout'

module Ridley
  class ConnectorSupervisor < ::Celluloid::SupervisionGroup
    # @param [Celluloid::Registry] registry
    def initialize(registry)
      super(registry)
      supervise_as :ssh, HostConnector::SSH
      supervise_as :winrm, HostConnector::WinRM
    end
  end

  class HostCommander
    class << self
      # Checks to see if the given port is open for TCP connections
      # on the given host.
      #
      # @param [String] host
      #   the host to attempt to connect to
      # @param [Fixnum] port
      #   the port to attempt to connect on
      # @param [Float] timeout
      #   the number of seconds to wait (default: {PORT_CHECK_TIMEOUT})
      #
      # @return [Boolean]
      def connector_port_open?(host, port, timeout = nil)
        Timeout.timeout(timeout || PORT_CHECK_TIMEOUT) { TCPSocket.new(host, port).close; true }
      rescue Timeout::Error, SocketError, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::EADDRNOTAVAIL => ex
        false
      end
    end

    include Celluloid
    include Ridley::Logging

    PORT_CHECK_TIMEOUT = 3

    finalizer :finalize_callback

    def initialize
      @connector_registry   = Celluloid::Registry.new
      @connector_supervisor = ConnectorSupervisor.new_link(@connector_registry)
    end

    # Execute a shell command on a node
    #
    # @param [String] host
    #   the host to perform the action on
    # @param [String] command
    #
    # @option options [Hash] :ssh
    #   * :user (String) a shell user that will login to each node and perform the bootstrap command on
    #   * :password (String) the password for the shell user that will perform the bootstrap
    #   * :keys (Array, String) an array of key(s) to authenticate the ssh user with instead of a password
    #   * :timeout (Float) timeout value for SSH bootstrap (5.0)
    #   * :sudo (Boolean) run as sudo
    # @option options [Hash] :winrm
    #   * :user (String) a user that will login to each node and perform the bootstrap command on
    #   * :password (String) the password for the user that will perform the bootstrap (required)
    #   * :port (Fixnum) the winrm port to connect on the node the bootstrap will be performed on (5985)
    #
    # @return [HostConnector::Response]
    def run(host, command, options = {})
      execute(__method__, host, command, options)
    end

    # Bootstrap a node
    #
    # @param [String] host
    #   the host to perform the action on
    #
    # @option options [Hash] :ssh
    #   * :user (String) a shell user that will login to each node and perform the bootstrap command on
    #   * :password (String) the password for the shell user that will perform the bootstrap
    #   * :keys (Array, String) an array of key(s) to authenticate the ssh user with instead of a password
    #   * :timeout (Float) timeout value for SSH bootstrap (5.0)
    #   * :sudo (Boolean) run as sudo
    # @option options [Hash] :winrm
    #   * :user (String) a user that will login to each node and perform the bootstrap command on
    #   * :password (String) the password for the user that will perform the bootstrap (required)
    #   * :port (Fixnum) the winrm port to connect on the node the bootstrap will be performed on (5985)
    #
    # @return [HostConnector::Response]
    def bootstrap(host, options = {})
      execute(__method__, host, options)
    end

    # Perform a chef client run on a node
    #
    # @param [String] host
    #   the host to perform the action on
    #
    # @option options [Hash] :ssh
    #   * :user (String) a shell user that will login to each node and perform the bootstrap command on
    #   * :password (String) the password for the shell user that will perform the bootstrap
    #   * :keys (Array, String) an array of key(s) to authenticate the ssh user with instead of a password
    #   * :timeout (Float) timeout value for SSH bootstrap (5.0)
    #   * :sudo (Boolean) run as sudo
    # @option options [Hash] :winrm
    #   * :user (String) a user that will login to each node and perform the bootstrap command on
    #   * :password (String) the password for the user that will perform the bootstrap (required)
    #   * :port (Fixnum) the winrm port to connect on the node the bootstrap will be performed on (5985)
    #
    # @return [HostConnector::Response]
    def chef_client(host, options = {})
      execute(__method__, host, options)
    end

    # Write your encrypted data bag secret on a node
    #
    # @param [String] host
    #   the host to perform the action on
    # @param [String] secret
    #   your organization's encrypted data bag secret
    #
    # @option options [Hash] :ssh
    #   * :user (String) a shell user that will login to each node and perform the bootstrap command on
    #   * :password (String) the password for the shell user that will perform the bootstrap
    #   * :keys (Array, String) an array of key(s) to authenticate the ssh user with instead of a password
    #   * :timeout (Float) timeout value for SSH bootstrap (5.0)
    #   * :sudo (Boolean) run as sudo
    # @option options [Hash] :winrm
    #   * :user (String) a user that will login to each node and perform the bootstrap command on
    #   * :password (String) the password for the user that will perform the bootstrap (required)
    #   * :port (Fixnum) the winrm port to connect on the node the bootstrap will be performed on (5985)
    #
    # @return [HostConnector::Response]
    def put_secret(host, secret, options = {})
      execute(__method__, host, secret, options)
    end

    # Execute line(s) of Ruby code on a node using Chef's embedded Ruby
    #
    # @param [String] host
    #   the host to perform the action on
    # @param [Array<String>] command_lines
    #   An Array of lines of the command to be executed
    #
    # @option options [Hash] :ssh
    #   * :user (String) a shell user that will login to each node and perform the bootstrap command on
    #   * :password (String) the password for the shell user that will perform the bootstrap
    #   * :keys (Array, String) an array of key(s) to authenticate the ssh user with instead of a password
    #   * :timeout (Float) timeout value for SSH bootstrap (5.0)
    #   * :sudo (Boolean) run as sudo
    # @option options [Hash] :winrm
    #   * :user (String) a user that will login to each node and perform the bootstrap command on
    #   * :password (String) the password for the user that will perform the bootstrap (required)
    #   * :port (Fixnum) the winrm port to connect on the node the bootstrap will be performed on (5985)
    #
    # @return [HostConnector::Response]
    def ruby_script(host, command_lines, options = {})
      execute(__method__, host, command_lines, options)
    end

    private

      def execute(method, host, *args)
        options = args.last.is_a?(Hash) ? args.pop : Hash.new

        connector_for(host, options).send(method, host, *args, options)
      rescue Errors::HostConnectionError => ex
        abort(ex)
      end

      # Finds and returns the best HostConnector for a given host
      #
      # @param [String] host
      #   the host to attempt to connect to
      # @option options [Hash] :ssh
      #   * :port (Fixnum) the ssh port to connect on the node the bootstrap will be performed on (22)
      #   * :timeout (Float) [5.0] timeout value for testing SSH connection
      # @option options [Hash] :winrm
      #   * :port (Fixnum) the winrm port to connect on the node the bootstrap will be performed on (5985)
      # @param block [Proc]
      #   an optional block that is yielded the best HostConnector
      #
      # @return [Symbol]
      def connector_for(host, options = {})
        options = options.reverse_merge(ssh: Hash.new, winrm: Hash.new)
        options[:ssh][:port]   ||= HostConnector::SSH::DEFAULT_PORT
        options[:winrm][:port] ||= HostConnector::WinRM::DEFAULT_PORT

        if self.class.connector_port_open?(host, options[:winrm][:port])
          options.delete(:ssh)
          winrm
        elsif self.class.connector_port_open?(host, options[:ssh][:port], options[:ssh][:timeout])
          options.delete(:winrm)
          ssh
        else
          raise Errors::HostConnectionError, "No connector ports open on '#{host}'"
        end
      end

      def finalize_callback
        @connector_supervisor.terminate if @connector_supervisor && @connector_supervisor.alive?
      end

      def ssh
        @connector_registry[:ssh]
      end

      def winrm
        @connector_registry[:winrm]
      end
  end
end
