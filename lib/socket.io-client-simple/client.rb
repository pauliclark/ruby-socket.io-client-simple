module SocketIO
  module Client
    module Simple

      def self.connect(url, opts={})
        client = Client.new(url, opts)
        client.connect
        return client
      end

      class Client
        include EventEmitter
        alias_method :__emit, :emit

        attr_accessor :auto_reconnection, :websocket, :url, :reconnecting, :state, :attempts,
                      :session_id, :ping_interval, :ping_timeout, :last_pong_at, :last_ping_at

        def initialize(url, opts={})
          @url = url
          @opts = opts
          @opts[:transport] = :websocket
          @reconnecting = false
          @state = :disconnect
          @auto_reconnection = true
          @attempts = 0

          this = self

        end


        def connect
          this = self
          query = @opts.map{|k,v| URI.encode "#{k}=#{v}" }.join '&'
          begin
            
            @attempts += 1
            puts "Connect socket attempt #{@attempts} to #{@url}"
            threadCount=Thread.list.select {|thread| thread.status == "run"}.count
            #puts "Threads #{threadCount} counted"
            @websocket = WebSocket::Client::Simple.connect "#{@url}/socket.io/?#{query}"
            puts 'Socket connected'

            begin
              Thread.new do
                loop do
                  if @websocket
                    if @state == :connect
                      if Time.now.to_i - this.last_pong_at > @ping_interval/1000
                        @websocket.send "2"  ## ping
                        this.last_pong_at = Time.now.to_i
                      end
                      #puts "#{@url} last pong #{this.last_pong_at}"
                    end
                    if @websocket.open? and Time.now.to_i - this.last_pong_at > @ping_timeout/1000
                      @websocket.close
                      @state = :disconnect
                      __emit :disconnect
                      reconnect
                      break
                    else
                      sleep 1
                    end
                  else
                    break
                  end
                end
              end
            rescue Exception => e
              p e
            end

          rescue Errno::ECONNREFUSED => e
            puts "Connection refused to #{@url}"
            this.state = :disconnect
            @reconnecting = false
            #this.__emit :disconnect
           # puts "Emit disconnect"
            reconnect
            return
          end
          @reconnecting = false


          @websocket.on :error do |err|
            if err.kind_of? Errno::ECONNRESET and this.state == :connect
              puts 'Connection reset'
              begin
                this.state = :disconnect
                this.__emit :disconnect
                @reconnecting = false
                puts 'Reconnect'
                this.reconnect
              rescue Exception => e
                p e
              end
              next
            end
            this.__emit :error, err
          end

          @websocket.on :message do |msg|
           #puts msg
            next unless msg.data =~ /^\d+/
            code, body = msg.data.scan(/^(\d+)(.*)$/)[0]
            code = code.to_i
           # puts code
           # puts body
            this.reconnecting = false
            case code
            when 0  ##  socket.io connect
              puts 'Socket connection'
              body = JSON.parse body rescue next
              this.session_id = body["sid"] || "no_sid"
              this.ping_interval = body["pingInterval"] || 25000
              this.ping_timeout  = body["pingTimeout"]  || 60000
              this.last_ping_at = Time.now.to_i
              this.last_pong_at = Time.now.to_i
              this.state = :connect
              this.__emit :connect
            when 3  ## pong
             # puts "Pong from #{@url}"
              this.last_pong_at = Time.now.to_i
            when 41  ## disconnect from server
              this.websocket.close if this.websocket.open?
              this.state = :disconnect
              this.__emit :disconnect
              this.reconnect
            when 42  ## data
             # p body
              data = JSON.parse body rescue next
              event_name = data.shift
             # p event_name
              this.__emit event_name, *data
            end
          end

          return self
        end


        def close
          puts 'Socket closing'
         @websocket.close unless @websocket.nil?
        end
        def reconnect
          puts "Attempts #{ attempts}"
          if @attempts<200
            begin
              close if open?
            ensure
              puts 'Already reconnecting' if @reconnecting
              puts 'No auto reconnect'  unless @auto_reconnection
              return unless @auto_reconnection
              return if @reconnecting
              @reconnecting = true
              sleep rand(5) + 5
             # puts "Socket reconnect attempt #{@attempts}"
              connect
            end
          end
        end

        def open?
          @websocket and @websocket.open?
        end

        def emit(event_name, *data)
          return unless open?
          return unless @state == :connect
          data.unshift event_name
          @websocket.send "42#{data.to_json}"
        end

        def disconnect
          puts "Disconnected from #{@url}"
          @auto_reconnection = false
          begin
            close
          ensure
           @state = :disconnect
          end
        end

      end

    end
  end
end
