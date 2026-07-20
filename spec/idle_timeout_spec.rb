# frozen_string_literal: true

require 'spec_helper'

describe Pond, "idle_timeout" do
  class FinishableObject
    attr_reader :finished

    def initialize
      @finished = false
    end

    def finish
      @finished = true
    end
  end

  def wait_until(timeout: 3, interval: 0.05)
    deadline = Time.now + timeout
    loop do
      return true if yield
      return false if Time.now > deadline
      sleep interval
    end
  end

  it "should evict and finish an object that has been idle longer than idle_timeout" do
    object = nil
    pond = Pond.new(idle_timeout: 0.1) { object = FinishableObject.new }

    pond.checkout {}
    pond.available.should == [object]

    wait_until { pond.available.empty? }

    pond.available.should == []
    object.finished.should == true
  end

  it "should not evict an object that has been idle for less than idle_timeout" do
    pond = Pond.new(idle_timeout: 120) { Object.new }
    pond.checkout {}

    sleep 1.2

    pond.available.length.should == 1
  end

  it "should not evict an object based on the (unrelated, short) checkout timeout setting" do
    pond = Pond.new(timeout: 0.01, idle_timeout: 120) { Object.new }
    pond.checkout {}

    sleep 1.2

    pond.available.length.should == 1
  end
end
