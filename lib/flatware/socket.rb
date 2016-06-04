require 'ffi-rzmq'

module Flatware
  Error = Class.new StandardError

  Job = Struct.new :id, :args do
    attr_accessor :worker
    attr_writer :failed

    def failed?
      !!@failed
    end
  end

  extend self

  def logger
    @logger ||= Logger.new($stderr)
  end

  def logger=(logger)
    @logger = logger
  end

  def socket(*args)
    context.socket(*args)
  end

  def close
    context.close
    @context = nil
  end

  def log(*message)
    if Exception === message.first
      logger.error message.first
    elsif verbose?
      logger.info ([$0] + message).join(' ')
    end
    message
  end

  attr_writer :verbose
  def verbose?
    !!@verbose
  end

  def context
    @context ||= Context.new
  end

  class Context
    attr_reader :sockets, :c

    def initialize
      @c = ZMQ::Context.new
      @sockets = []
    end

    def socket(zmq_type, options={})
      Socket.new(c.socket(zmq_type)).tap do |socket|
        sockets.push socket
        if port = options[:connect]
          socket.connect port
        end
        if port = options[:bind]
          socket.bind port
        end
      end
    end

    def close
      LibZMQ.zmq_ctx_shutdown c.context
      sockets.each do |socket|
        socket.close
      end
      raise(Error, ZMQ::Util.error_string, caller) unless c.terminate == 0
      Flatware.log "terminated context"
    end
  end

  class Socket
    attr_reader :s
    def initialize(socket)
      @s = socket
    end

    def setsockopt(*args)
      s.setsockopt(*args)
    end

    def send(message)
      result = s.send_string(Marshal.dump(message))
      raise Error, ZMQ::Util.error_string, caller if result == -1
      Flatware.log "#@type #@port send #{message}"
      message
    end

    def connect(port)
      @type = 'connected'
      @port = port
      raise(Error, ZMQ::Util.error_string, caller) unless s.connect(port) == 0
      Flatware.log "connect #@port"
    end

    def monitor
      name = "inproc://monitor#{rand(1000)}"
      LibZMQ.zmq_socket_monitor(s.socket, name, ZMQ::EVENT_ALL)
      Monitor.new(name)
    end

    class Monitor
      def initialize(port)
        @socket = Flatware.socket ZMQ::PAIR
        @socket.connect port
      end

      def recv
        bytes = @socket.recv marshal: false
        data = LibZMQ::EventData.new FFI::MemoryPointer.from_string bytes
        event[data.event]
      end

      private

      def event
        ZMQ.constants.select do |c|
          c.to_s =~ /^EVENT/
        end.map do |s|
          {s => ZMQ.const_get(s)}
        end.reduce(:merge).invert
      end
    end

    def bind(port)
      @type = 'bound'
      @port = port
      raise(Error, ZMQ::Util.error_string, caller) unless s.bind(port) == 0
      Flatware.log "bind #@port"
    end

    def close
      raise(Error, ZMQ::Util.error_string, caller) unless s.close == 0
      Flatware.log "close #@type #@port"
    end

    def recv(block: true, marshal: true)
      message = ''
      if block
       result = s.recv_string(message)
       raise Error, ZMQ::Util.error_string, caller if result == -1
      else
        s.recv_string(message, ZMQ::NOBLOCK)
      end
      if message != '' and marshal
        message = Marshal.load(message)
      end
      Flatware.log "#@type #@port recv #{message}"
      message
    end
  end
end
