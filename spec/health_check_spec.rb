# frozen_string_literal: true

require 'spec_helper'

describe Pond, "healthy_if" do
  # Scoped to these examples via stub_const so the helper class doesn't leak
  # into the rest of the suite as a top-level constant.
  let(:connection_class) do
    Class.new do
      attr_reader :finished

      def initialize
        @healthy  = true
        @finished = false
      end

      def healthy?
        @healthy
      end

      def unhealthy!
        @healthy = false
      end

      def finish
        @finished = true
      end
    end
  end

  before { stub_const("HealthCheckConnection", connection_class) }

  let(:healthy_if) { lambda { |conn| conn.healthy? } }

  it "should have its healthy_if gettable and settable" do
    pond = Pond.new { Object.new }
    pond.healthy_if.should == nil
    pond.healthy_if = healthy_if
    pond.healthy_if.should == healthy_if

    pond = Pond.new(healthy_if: healthy_if) { Object.new }
    pond.healthy_if.should == healthy_if
    pond.healthy_if = nil
    pond.healthy_if.should == nil
  end

  it "should raise if given a healthy_if that does not respond to #call" do
    procs = [
      proc { pond = Pond.new { Object.new }; pond.healthy_if = :blah },
      proc { Pond.new(healthy_if: :blah) { Object.new } },
    ]

    procs.each { |p| p.should raise_error RuntimeError, /Object given for Pond healthy_if must respond to #call/ }
  end

  it "should hand out the same pooled object when no healthy_if is configured" do
    int  = 0
    pond = Pond.new { int += 1 }

    pond.checkout { |i| i.should == 1 }
    pond.checkout { |i| i.should == 1 }

    pond.size.should == 1
    pond.available.should == [1]
  end

  it "should not hand out a pooled object that has become unhealthy while idle" do
    pond = Pond.new(healthy_if: healthy_if) { HealthCheckConnection.new }

    first = nil
    pond.checkout { |conn| first = conn }
    pond.available.should == [first]

    first.unhealthy!

    second = nil
    pond.checkout { |conn| second = conn }

    second.should_not == first
  end

  it "should yield a healthy object when the pooled object was unhealthy" do
    pond = Pond.new(healthy_if: healthy_if) { HealthCheckConnection.new }

    pond.checkout { |conn| conn }
    pond.available.first.unhealthy!

    yielded = nil
    pond.checkout { |conn| yielded = conn }

    yielded.healthy?.should == true
  end

  it "should finish an unhealthy object when discarding it on checkout" do
    pond = Pond.new(healthy_if: healthy_if) { HealthCheckConnection.new }

    first = nil
    pond.checkout { |conn| first = conn }
    first.unhealthy!

    pond.checkout {}

    first.finished.should == true
  end

  it "should remove the discarded unhealthy object from the pool" do
    pond = Pond.new(healthy_if: healthy_if) { HealthCheckConnection.new }

    first = nil
    pond.checkout { |conn| first = conn }
    first.unhealthy!

    pond.checkout {}

    pond.available.should_not include(first)
  end

  it "should replace an unhealthy object even when already at maximum_size" do
    pond = Pond.new(maximum_size: 1, healthy_if: healthy_if) { HealthCheckConnection.new }

    first = nil
    pond.checkout { |conn| first = conn }
    first.unhealthy!

    second = nil
    pond.checkout { |conn| second = conn }

    second.should_not == first
    second.healthy?.should == true
    pond.size.should == 1
  end

  it "should never yield an unhealthy object under sustained concurrent checkouts" do
    pond = Pond.new(maximum_size: 5, idle_timeout: 0.05, timeout: 5, healthy_if: healthy_if) { HealthCheckConnection.new }

    unhealthy_yields = Queue.new
    stop = Queue.new # closed to signal shutdown; Queue#closed? is thread-safe

    threads = 8.times.map do
      Thread.new do
        until stop.closed?
          pond.checkout do |conn|
            unhealthy_yields << conn unless conn.healthy?
            conn.unhealthy! if rand < 0.3
          end
        end
      end
    end

    sleep 2
    stop.close
    threads.each(&:join)

    unhealthy_yields.should be_empty
  end
end
