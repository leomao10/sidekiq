require 'sinatra/base'
require 'slim'
require 'sprockets'
module Sidekiq
  class SprocketsMiddleware
    def initialize(app, options={})
      @app = app
      @root = options[:root]
      path   =  options[:path] || 'assets'
      @matcher = /^\/#{path}\/*/
      @environment = ::Sprockets::Environment.new(@root)
      @environment.append_path 'assets/javascripts'
      @environment.append_path 'assets/javascripts/vendor'
      @environment.append_path 'assets/stylesheets'
      @environment.append_path 'assets/stylesheets/vendor'
      @environment.append_path 'assets/images'
    end

    def call(env)
      # Solve the problem of people requesting /sidekiq when they need to request /sidekiq/ so
      # that relative links in templates resolve correctly.
      return [301, { 'Location' => "#{env['SCRIPT_NAME']}/", 'Content-Type' => 'text/html' }, ['redirecting']] if env['SCRIPT_NAME'] == env['REQUEST_PATH']

      return @app.call(env) unless @matcher =~ env["PATH_INFO"]
      env['PATH_INFO'].sub!(@matcher,'')
      @environment.call(env)
    end
  end

  class Web < Sinatra::Base
    dir = File.expand_path(File.dirname(__FILE__) + "/../../web")
    set :views,  "#{dir}/views"
    set :root, "#{dir}/public"
    set :slim, :pretty => true
    use SprocketsMiddleware, :root => dir

    helpers do

      def reset_worker_list
        Sidekiq.redis do |conn|
          workers = conn.smembers('workers')
          workers.each do |name|
            conn.srem('workers', name)
          end
        end
      end

      def workers
        @workers ||= begin
          Sidekiq.redis do |conn|
            conn.smembers('workers').map do |w|
              msg = conn.get("worker:#{w}")
              msg ? [w, Sidekiq.load_json(msg)] : nil
            end.compact.sort { |x| x[1] ? -1 : 1 }
          end
        end
      end

      def processed
        Sidekiq.redis { |conn| conn.get('stat:processed') } || 0
      end

      def failed
        Sidekiq.redis { |conn| conn.get('stat:failed') } || 0
      end

      def failures
        Sidekiq.redis do |conn|
          results = conn.lrange('failed', 0, -1)
          results.map { |msg| Sidekiq.load_json(msg) }
        end
      end

      def zcard(name)
        Sidekiq.redis { |conn| conn.zcard(name) }
      end

      def retries(count=50)
        zcontents('retry', count)
      end

      def scheduled(count=50)
        zcontents('schedule', count)
      end

      def zcontents(name, count)
        Sidekiq.redis do |conn|
          results = conn.zrange(name, 0, count, :withscores => true)
          results.map { |msg, score| [Sidekiq.load_json(msg), score] }
        end
      end

      def queues
        @queues ||= Sidekiq.redis do |conn|
          conn.smembers('queues').map do |q|
            [q, conn.llen("queue:#{q}") || 0]
          end.sort { |x,y| x[1] <=> y[1] }
        end
      end

      def backlog
        queues.map {|name, size| size }.inject(0) {|memo, val| memo + val }
      end

      def retries_with_score(score)
        Sidekiq.redis do |conn|
          results = conn.zrangebyscore('retry', score, score)
          results.map { |msg| Sidekiq.load_json(msg) }
        end
      end

      def location
        Sidekiq.redis { |conn| conn.client.location }
      end

      def root_path
        "#{env['SCRIPT_NAME']}/"
      end

      def current_status
        return 'idle' if workers.size == 0
        return 'active'
      end

      def relative_time(time)
        %{<time datetime="#{time.getutc.iso8601}">#{time}</time>}
      end

      def display_args(args, count=100)
        args.map { |arg| a = arg.inspect; a.size > count ? "#{a[0..count]}..." : a }.join(", ")
      end
    end

    get "/" do
      slim :index
    end

    get "/queues" do
      @queues = queues
      slim :queues
    end

    get "/queues/:name" do
      halt 404 unless params[:name]
      count = (params[:count] || 10).to_i
      @name = params[:name]
      @messages = Sidekiq.redis {|conn| conn.lrange("queue:#{@name}", 0, count) }.map { |str| Sidekiq.load_json(str) }
      slim :queue
    end

    post "/reset" do
      reset_worker_list
      redirect root_path
    end

    post "/queues/:name" do
      Sidekiq.redis do |conn|
        conn.del("queue:#{params[:name]}")
        conn.srem("queues", params[:name])
      end
      redirect "#{root_path}queues"
    end

    get "/failures" do
      @failures = failures
      slim :failures
    end

    get "/retries/:score" do
      halt 404 unless params[:score]
      @score = params[:score].to_f
      @retries = retries_with_score(@score)
      redirect "#{root_path}retries" if @retries.empty?
      slim :retry
    end

    get '/retries' do
      @retries = retries
      slim :retries
    end

    get '/scheduled' do
      @scheduled = scheduled
      slim :scheduled
    end

    post '/scheduled' do
      halt 404 unless params[:score]
      halt 404 unless params['delete']
      params[:score].each do |score|
        s = score.to_f
        process_score('schedule', s, :delete)
      end
      redirect "#{root_path}scheduled"
    end

    post '/failures' do
      Sidekiq.redis do |conn|
        conn.del('failed')
      end
      redirect "#{root_path}failures"
    end

    post '/retries' do
      halt 404 unless params[:score]
      params[:score].each do |score|
        s = score.to_f
        if params['retry']
          process_score('retry', s, :retry)
        elsif params['delete']
          process_score('retry', s, :delete)
        end
      end
      redirect "#{root_path}retries"
    end

    post "/retries/:score" do
      halt 404 unless params[:score]
      score = params[:score].to_f
      if params['retry']
        process_score('retry', score, :retry)
      elsif params['delete']
        process_score('retry', score, :delete)
      end
      redirect "#{root_path}retries"
    end

    def process_score(set, score, operation)
      case operation
      when :retry
        Sidekiq.redis do |conn|
          results = conn.zrangebyscore(set, score, score)
          conn.zremrangebyscore(set, score, score)
          results.map do |message|
            msg = Sidekiq.load_json(message)
            msg['retry_count'] = msg['retry_count'] - 1
            conn.rpush("queue:#{msg['queue']}", Sidekiq.dump_json(msg))
          end
        end
      when :delete
        Sidekiq.redis do |conn|
          conn.zremrangebyscore(set, score, score)
        end
      end
    end

  end

end
