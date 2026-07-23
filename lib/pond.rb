# frozen_string_literal: true

require 'monitor'

require 'pond/version'

class Pond
  class Timeout < StandardError; end

  attr_reader :allocated, :available, :timeout, :collection, :maximum_size, :detach_if, :healthy_if

  DEFAULT_DETACH_IF = lambda { |_| false }

  def initialize(
    maximum_size: 10,
    eager: false,
    timeout: 1,
    collection: :queue,
    detach_if: DEFAULT_DETACH_IF,
    healthy_if: nil,
    idle_timeout: 120,
    &block
  )
    @block   = block
    @monitor = Monitor.new
    @cv      = MonitorMixin::ConditionVariable.new(@monitor)

    @allocated = {}
    @available = Array.new(eager ? maximum_size : 0, &block)
    @last_used = {}

    self.timeout      = timeout
    self.collection   = collection
    self.detach_if    = detach_if
    self.healthy_if   = healthy_if
    self.maximum_size = maximum_size
    self.idle_timeout = idle_timeout

    @connection_manager = Thread.new { monitor_connections }
  end

  def checkout(scope: nil, &block)
    raise "Can't checkout with a non-frozen scope" unless scope.frozen?

    if (object = current_object(scope: scope))
      yield object
    else
      checkout_object(scope: scope, &block)
    end
  end

  def size
    sync { @allocated.inject(@available.size){|sum, (h, k)| sum + k.length} }
  end

  def timeout=(timeout)
    raise "Bad value for Pond timeout: #{timeout.inspect}" unless Numeric === timeout && timeout >= 0
    sync { @timeout = timeout }
  end

  def collection=(type)
    raise "Bad value for Pond collection: #{type.inspect}" unless [:stack, :queue].include?(type)
    sync { @collection = type }
  end

  def maximum_size=(max)
    raise "Bad value for Pond maximum_size: #{max.inspect}" unless Integer === max && max >= 0
    sync do
      @maximum_size = max
      {} until size <= max || pop_object.nil?
    end
  end

  def detach_if=(callable)
    raise "Object given for Pond detach_if must respond to #call" unless callable.respond_to?(:call)
    sync { @detach_if = callable }
  end

  def healthy_if=(callable)
    raise "Object given for Pond healthy_if must respond to #call" unless callable.nil? || callable.respond_to?(:call)
    sync { @healthy_if = callable }
  end

  def idle_timeout=(idle_timeout)
    raise "Bad value for Pond idle_timeout: #{idle_timeout.inspect}" unless Numeric === idle_timeout && idle_timeout >= 0
    sync { @idle_timeout = idle_timeout }
  end

  private

  def monitor_connections
    while true do
      evicted = []

      # Collect idle objects under the lock, but call #finish outside it: a
      # slow #finish (e.g. a network round-trip to close a connection) must
      # not hold the monitor and stall every concurrent checkout.
      sync do
        @last_used.filter { |_k,v| Time.now - v >= @idle_timeout }
                  .each_key do |k|
          evicted << @available.delete(k)
          @last_used.delete(k)
        end
      end

      evicted.each do |obj|
        next unless obj.respond_to?(:finish)

        begin
          obj.finish
        rescue => e
          # Best-effort cleanup; a raising #finish must not kill the eviction
          # thread and stop all future idle eviction.
          warn "Pond idle eviction: #finish raised, ignoring: #{e.class}: #{e.message}"
        end
      end

      sleep 1
    end
  end

  def checkout_object(scope:)
    lock_object(scope: scope)
    yield current_object(scope: scope)
  ensure
    unlock_object(scope: scope)
  end

  def lock_object(scope:)
    deadline = Time.now + @timeout

    until current_object(scope: scope)
      raise Timeout if (time_left = deadline - Time.now) < 0

      obtained = false
      sync do
        if (object = get_object(time_left))
          set_current_object(object, scope: scope)
          obtained = true
        end
      end

      discard_current_object_unless_healthy(scope: scope) if obtained
    end

    # We need to protect changes to @allocated and @available with the monitor
    # so that #size always returns the correct value. But, we don't want to
    # call the instantiation block while we have the lock, since it may take a
    # long time to return. So, we set the checked-out object to the block as a
    # signal that it needs to be called.
    if current_object(scope: scope) == @block
      set_current_object(@block.call, scope: scope)
    end
  end

  def unlock_object(scope:)
    object               = nil
    detach_if            = nil
    should_return_object = nil

    sync do
      object               = current_object(scope: scope)
      detach_if            = self.detach_if
      should_return_object = object && object != @block && size <= maximum_size
    end

    begin
      should_return_object = !detach_if.call(object) if should_return_object
      detach_check_finished = true
    ensure
      sync do
        if detach_check_finished && should_return_object
          @available << object
          @last_used[object] = Time.now
        end
        @allocated[scope].delete(Thread.current)
        @cv.signal
      end
    end
  end

  # A pooled object may have been closed out-of-band (e.g. by the server)
  # while it sat idle. We check its health here, outside the monitor, so that
  # a slow healthy_if (or the object's #finish) never blocks other threads. An
  # unhealthy object is dropped rather than returned, and the loop in
  # #lock_object obtains another one (or instantiates a fresh one).
  #
  # Contract: healthy_if runs on *every* checkout that pulls an object from the
  # pool, so it must be a cheap, local check (see README) — a per-checkout I/O
  # round-trip would tax the whole pool. Freshly instantiated objects (the
  # @block.call path in #lock_object) are deliberately not checked: they are
  # assumed healthy at birth, so the check only guards objects that have sat in
  # the pool.
  def discard_current_object_unless_healthy(scope:)
    object     = nil
    healthy_if = nil

    sync do
      object     = current_object(scope: scope)
      healthy_if = self.healthy_if
    end

    return if object.nil? || object == @block || healthy_if.nil?

    begin
      return if healthy_if.call(object)
    rescue => e
      # Treat a raising check as unhealthy and discard the object, rather than
      # returning a possibly-broken one to the pool. Surface the error so a bug
      # in healthy_if (which would silently churn every object) is diagnosable
      # instead of masquerading as normal eviction.
      warn "Pond healthy_if raised, discarding object: #{e.class}: #{e.message}"
    end

    sync do
      @allocated[scope].delete(Thread.current)
    end

    begin
      object.finish if object.respond_to?(:finish)
    rescue
      # Best-effort cleanup: the object is already out of the pool, so a
      # raising #finish (e.g. on an already-closed connection) must not
      # propagate out of #checkout.
    end
  end

  def get_object(timeout)
    pop_object || size < maximum_size && @block || @cv.wait(timeout) && false
  end

  def pop_object
    object =
      case collection
      when :queue then @available.shift
      when :stack then @available.pop
      end

    @last_used.delete(object) if object
    object
  end

  def current_object(scope:)
    sync { (@allocated[scope] ||= {})[Thread.current] }
  end

  def set_current_object(object, scope:)
    sync { (@allocated[scope] ||= {})[Thread.current] = object }
  end

  def sync(&block)
    @monitor.synchronize(&block)
  end

  class << self
    def wrap(*args, &block)
      Wrapper.new(*args, &block)
    end
  end

  class Wrapper < BasicObject
    attr_reader :pond

    def initialize(*args, **kwargs, &block)
      @pond = ::Pond.new(*args, **kwargs, &block)
    end

    def method_missing(*args, **kwargs, &block)
      @pond.checkout { |object| object.public_send(*args, **kwargs, &block) }
    end
  end
end
