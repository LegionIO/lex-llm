# frozen_string_literal: true

require 'openssl'
require 'socket'
require 'tempfile'
require 'timeout'

module SpecSupport
  # One real HTTPS exchange, using a fresh private CA rather than external trust.
  class TlsEndpoint
    attr_reader :url, :ca_file, :requests

    def initialize(subject_alt_name: 'IP:127.0.0.1')
      ca_key = OpenSSL::PKey::EC.generate('prime256v1')
      ca = certificate(key: ca_key, name: 'lex-llm test CA')
      ca_extensions = OpenSSL::X509::ExtensionFactory.new
      ca_extensions.subject_certificate = ca
      ca_extensions.issuer_certificate = ca
      ca.add_extension(ca_extensions.create_extension('basicConstraints', 'CA:TRUE', true))
      ca.add_extension(ca_extensions.create_extension('keyUsage', 'keyCertSign,cRLSign', true))
      ca.sign(ca_key, OpenSSL::Digest.new('SHA256'))

      key = OpenSSL::PKey::EC.generate('prime256v1')
      cert = certificate(key: key, name: 'lex-llm test endpoint')
      cert.issuer = ca.subject
      extensions = OpenSSL::X509::ExtensionFactory.new
      extensions.subject_certificate = cert
      extensions.issuer_certificate = ca
      cert.add_extension(extensions.create_extension('basicConstraints', 'CA:FALSE', true))
      cert.add_extension(extensions.create_extension('keyUsage', 'digitalSignature', true))
      cert.add_extension(extensions.create_extension('extendedKeyUsage', 'serverAuth'))
      cert.add_extension(extensions.create_extension('subjectAltName', subject_alt_name))
      cert.sign(ca_key, OpenSSL::Digest.new('SHA256'))

      @ca_file = Tempfile.new(['lex-llm-ca', '.pem'])
      @ca_file.write(ca.to_pem)
      @ca_file.flush
      @requests = []
      @listener = TCPServer.new('127.0.0.1', 0)
      @url = "https://127.0.0.1:#{@listener.addr[1]}"
      context = OpenSSL::SSL::SSLContext.new
      context.cert = cert
      context.key = key
      server = OpenSSL::SSL::SSLServer.new(@listener, context)
      @worker = Thread.new { serve(server: server) }
    end

    def finish
      raise Timeout::Error, 'TLS fixture did not finish its exchange' unless @worker.join(5)

      @worker.value
    end

    def close
      @worker&.kill
      @worker&.join
      @listener&.close
      @ca_file&.close!
    end

    private

    def certificate(key:, name:)
      cert = OpenSSL::X509::Certificate.new
      cert.version = 2
      cert.serial = OpenSSL::BN.rand(128).to_i
      cert.subject = OpenSSL::X509::Name.parse("/CN=#{name}")
      cert.issuer = cert.subject
      cert.public_key = key
      cert.not_before = Time.now - 60
      cert.not_after = Time.now + 3600
      cert
    end

    def serve(server:)
      socket = server.accept
      request = +''
      while (line = socket.gets) && line != "\r\n"
        request << line
      end
      return if request.empty?

      @requests << request
      body = '{"status":"ok"}'
      socket.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
    rescue OpenSSL::SSL::SSLError => e
      Legion::Logging.debug("TLS fixture handshake rejected: #{e.class}")
    ensure
      socket&.close
    end
  end
end
