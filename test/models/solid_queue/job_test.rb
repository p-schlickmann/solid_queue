require "test_helper"

class SolidQueue::JobTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  class NonOverlappingJob < ApplicationJob
    limits_concurrency key: ->(job_result, **) { job_result }

    def perform(job_result)
    end
  end

  class DiscardableNonOverlappingJob < NonOverlappingJob
    limits_concurrency key: ->(job_result, **) { job_result }, on_conflict: :discard
  end

  class DiscardableThrottledJob < NonOverlappingJob
    limits_concurrency to: 2, key: ->(job_result, **) { job_result }, on_conflict: :discard
  end

  class NonOverlappingGroupedJob1 < NonOverlappingJob
    limits_concurrency key: ->(job_result, **) { job_result }, group: "MyGroup"
  end

  class NonOverlappingGroupedJob2 < NonOverlappingJob
    limits_concurrency key: ->(job_result, **) { job_result }, group: "MyGroup"
  end

  class DiscardableNonOverlappingGroupedJob1 < NonOverlappingJob
    limits_concurrency key: ->(job_result, **) { job_result }, group: "DiscardingGroup", on_conflict: :discard
  end

  class DiscardableNonOverlappingGroupedJob2 < NonOverlappingJob
    limits_concurrency key: ->(job_result, **) { job_result }, group: "DiscardingGroup", on_conflict: :discard
  end

  setup do
    @result = JobResult.create!(queue_name: "default")
    @discarded_concurrent_error = SolidQueue::Job::EnqueueError.new(
      "Dispatched job discarded due to concurrent configuration."
    )
  end

  test "enqueue active job to be executed right away" do
    active_job = AddToBufferJob.new(1).set(priority: 8, queue: "test")

    assert_ready do
      SolidQueue::Job.enqueue(active_job)
    end

    solid_queue_job = SolidQueue::Job.last
    assert solid_queue_job.ready?
    assert_equal :ready, solid_queue_job.status
    assert_equal solid_queue_job.id, active_job.provider_job_id
    assert_equal 8, solid_queue_job.priority
    assert_equal "test", solid_queue_job.queue_name
    assert_equal "AddToBufferJob", solid_queue_job.class_name
    assert Time.now >= solid_queue_job.scheduled_at
    assert_equal [ 1 ], solid_queue_job.arguments["arguments"]

    execution = SolidQueue::ReadyExecution.last
    assert_equal solid_queue_job, execution.job
    assert_equal "test", execution.queue_name
    assert_equal 8, execution.priority
  end

  test "enqueue active job to be scheduled in the future" do
    active_job = AddToBufferJob.new(1).set(priority: 8, queue: "test")

    assert_scheduled do
      SolidQueue::Job.enqueue(active_job, scheduled_at: 5.minutes.from_now)
    end

    solid_queue_job = SolidQueue::Job.last
    assert solid_queue_job.scheduled?
    assert_equal :scheduled, solid_queue_job.status
    assert_equal 8, solid_queue_job.priority
    assert_equal "test", solid_queue_job.queue_name
    assert_equal "AddToBufferJob", solid_queue_job.class_name
    assert Time.now < solid_queue_job.scheduled_at
    assert_equal [ 1 ], solid_queue_job.arguments["arguments"]

    execution = SolidQueue::ScheduledExecution.last
    assert_equal solid_queue_job, execution.job
    assert_equal "test", execution.queue_name
    assert_equal 8, execution.priority
    assert_equal solid_queue_job.scheduled_at, execution.scheduled_at
  end

  test "enqueue jobs within a connected_to block for the primary DB" do
    ShardedRecord.connected_to(role: :writing, shard: :shard_two) do
      ShardedJobResult.create!(value: "in shard two")
      AddToBufferJob.perform_later("enqueued within block")
    end

    job = SolidQueue::Job.last
    assert_equal "enqueued within block", job.arguments.dig("arguments", 0)
  end

  test "enqueue jobs without concurrency controls" do
    active_job = AddToBufferJob.perform_later(1)
    assert_nil active_job.concurrency_limit
    assert_nil active_job.concurrency_key

    job = SolidQueue::Job.last
    assert_nil job.concurrency_limit
    assert_not job.concurrency_limited?
  end

  test "enqueue jobs with concurrency controls" do
    active_job = NonOverlappingJob.perform_later(@result, name: "A")
    assert_equal 1, active_job.concurrency_limit
    assert_equal "SolidQueue::JobTest::NonOverlappingJob/JobResult/#{@result.id}", active_job.concurrency_key

    job = SolidQueue::Job.last
    assert_equal active_job.concurrency_limit, job.concurrency_limit
    assert_equal active_job.concurrency_key, job.concurrency_key
  end

  test "block jobs when concurrency limits are reached" do
    assert_ready do
      NonOverlappingJob.perform_later(@result, name: "A")
    end

    assert_blocked do
      NonOverlappingJob.perform_later(@result, name: "B")
    end

    blocked_execution = SolidQueue::BlockedExecution.last
    assert blocked_execution.expires_at <= SolidQueue.default_concurrency_control_period.from_now
  end

  test "skips jobs with on_conflict set to discard when concurrency limits are reached" do
    assert_job_counts(ready: 1) do
      DiscardableNonOverlappingJob.perform_later(@result, name: "A")
      DiscardableNonOverlappingJob.perform_later(@result, name: "B")
    end
  end

  test "block jobs in the same concurrency group when concurrency limits are reached" do
    assert_ready do
      active_job = NonOverlappingGroupedJob1.perform_later(@result, name: "A")
      assert_equal 1, active_job.concurrency_limit
      assert_equal "MyGroup/JobResult/#{@result.id}", active_job.concurrency_key
    end

    assert_blocked do
      active_job = NonOverlappingGroupedJob2.perform_later(@result, name: "B")
      assert_equal 1, active_job.concurrency_limit
      assert_equal "MyGroup/JobResult/#{@result.id}", active_job.concurrency_key
    end
  end

  test "skips jobs with on_conflict set to discard in the same concurrency group when concurrency limits are reached" do
    assert_job_counts(ready: 1) do
      active_job = DiscardableNonOverlappingGroupedJob1.perform_later(@result, name: "A")
      assert_equal 1, active_job.concurrency_limit
      assert_equal "DiscardingGroup/JobResult/#{@result.id}", active_job.concurrency_key

      active_job = DiscardableNonOverlappingGroupedJob2.perform_later(@result, name: "B")
      assert_equal 1, active_job.concurrency_limit
      assert_equal "DiscardingGroup/JobResult/#{@result.id}", active_job.concurrency_key
    end
  end

  test "enqueue scheduled job with concurrency controls and on_conflict set to discard" do
    assert_ready do
      DiscardableNonOverlappingJob.perform_later(@result, name: "A")
    end

    assert_scheduled do
      DiscardableNonOverlappingJob.set(wait: 5.minutes).perform_later(@result, name: "B")
    end

    scheduled_job = SolidQueue::Job.last

    travel_to 10.minutes.from_now

    # The scheduled job is not enqueued because it conflicts with
    # the first one and is discarded
    assert_equal 0, SolidQueue::ScheduledExecution.dispatch_next_batch(10)
    assert_nil SolidQueue::Job.find_by(id: scheduled_job.id)
  end

  test "enqueue jobs in bulk" do
    active_jobs = [
      AddToBufferJob.new(2),
      AddToBufferJob.new(6).set(wait: 2.minutes),
      NonOverlappingJob.new(@result),
      StoreResultJob.new(42),
      AddToBufferJob.new(4),
      NonOverlappingGroupedJob1.new(@result),
      AddToBufferJob.new(6).set(wait: 3.minutes),
      NonOverlappingJob.new(@result),
      NonOverlappingGroupedJob2.new(@result)
    ]

    assert_job_counts(ready: 5, scheduled: 2, blocked: 2) do
      ActiveJob.perform_all_later(active_jobs)
    end

    jobs = SolidQueue::Job.last(9)
    assert_equal active_jobs.map(&:provider_job_id).sort, jobs.pluck(:id).sort
    assert active_jobs.all?(&:successfully_enqueued?)
  end

  test "enqueues jobs in bulk with concurrency controls and some set to discard" do
    active_jobs = [
      AddToBufferJob.new(2),
      DiscardableNonOverlappingJob.new(@result),
      NonOverlappingJob.new(@result),
      AddToBufferJob.new(6).set(wait: 2.minutes),
      NonOverlappingJob.new(@result),
      DiscardableNonOverlappingJob.new(@result) # this one won't be enqueued
    ]
    not_enqueued = active_jobs.last

    assert_job_counts(ready: 3, scheduled: 1, blocked: 1) do
      ActiveJob.perform_all_later(active_jobs)
    end

    jobs = SolidQueue::Job.last(5)
    assert_equal active_jobs.without(not_enqueued).map(&:provider_job_id).sort, jobs.pluck(:id).sort
    assert active_jobs.without(not_enqueued).all?(&:successfully_enqueued?)

    assert_nil not_enqueued.provider_job_id
    assert_not not_enqueued.successfully_enqueued?
  end

  test "discard ready job" do
    AddToBufferJob.perform_later(1)
    job = SolidQueue::Job.last

    assert_job_counts ready: -1 do
      job.discard
    end
  end

  test "discard blocked job" do
    NonOverlappingJob.perform_later(@result, name: "ready")
    NonOverlappingJob.perform_later(@result, name: "blocked")
    ready_job, blocked_job = SolidQueue::Job.last(2)
    semaphore = SolidQueue::Semaphore.last

    travel_to 10.minutes.from_now

    assert_no_changes -> { semaphore.value }, -> { semaphore.expires_at } do
      assert_job_counts blocked: -1 do
        blocked_job.discard
      end
    end
  end

  test "try to discard claimed job" do
    StoreResultJob.perform_later(42, pause: 2.seconds)
    job = SolidQueue::Job.last

    worker = SolidQueue::Worker.new(queues: "background").tap(&:start)
    sleep(0.2)

    assert_no_difference -> { SolidQueue::Job.count }, -> { SolidQueue::ClaimedExecution.count } do
      assert_raises SolidQueue::Execution::UndiscardableError do
        job.discard
      end
    end

    worker.stop
  end

  test "discard scheduled job" do
    AddToBufferJob.set(wait: 5.minutes).perform_later
    job = SolidQueue::Job.last

    assert_job_counts scheduled: -1 do
      job.discard
    end
  end

  test "release blocked locks when discarding a ready job" do
    NonOverlappingJob.perform_later(@result, name: "ready")
    NonOverlappingJob.perform_later(@result, name: "blocked")
    ready_job, blocked_job = SolidQueue::Job.last(2)
    semaphore = SolidQueue::Semaphore.last

    assert ready_job.ready?
    assert blocked_job.blocked?

    travel_to 10.minutes.from_now

    assert_changes -> { semaphore.reload.expires_at } do
      assert_job_counts blocked: -1 do
        ready_job.discard
      end
    end

    assert blocked_job.reload.ready?
  end

  test "discard jobs by execution type in bulk" do
    active_jobs = [
      AddToBufferJob.new(2),
      AddToBufferJob.new(6).set(wait: 2.minutes),
      NonOverlappingJob.new(@result),
      StoreResultJob.new(42),
      AddToBufferJob.new(4),
      NonOverlappingGroupedJob1.new(@result),
      AddToBufferJob.new(6).set(wait: 3.minutes),
      NonOverlappingJob.new(@result),
      NonOverlappingGroupedJob2.new(@result)
    ]

    assert_job_counts(ready: 5, scheduled: 2, blocked: 2) do
      ActiveJob.perform_all_later(active_jobs)
    end

    assert_job_counts(ready: -5) do
      SolidQueue::ReadyExecution.discard_all_from_jobs(SolidQueue::Job.all)
    end

    assert_job_counts(scheduled: -2) do
      SolidQueue::ScheduledExecution.discard_all_from_jobs(SolidQueue::Job.all)
    end

    assert_job_counts(blocked: -2) do
      SolidQueue::BlockedExecution.discard_all_from_jobs(SolidQueue::Job.all)
    end
  end

  test "raise EnqueueError when there's an ActiveRecordError" do
    SolidQueue::Job.stubs(:create!).raises(ActiveRecord::Deadlocked)

    assert_raises SolidQueue::Job::EnqueueError do
      active_job = AddToBufferJob.new(1).set(priority: 8, queue: "test")
      SolidQueue::Job.enqueue(active_job)
    end

    assert_raises SolidQueue::Job::EnqueueError do
      AddToBufferJob.perform_later(1)
    end
  end

  test "enqueue successfully inside a rolled-back transaction in the app DB" do
    # Doesn't work with enqueue_after_transaction_commit? true on SolidQueueAdapter, but only Rails 7.2 uses this
    skip if Rails::VERSION::MAJOR == 7 && Rails::VERSION::MINOR == 2
    assert_difference -> { SolidQueue::Job.count } do
      assert_no_difference -> { JobResult.count } do
        JobResult.transaction do
          JobResult.create!(queue_name: "default", value: "this will be rolled back")
          StoreResultJob.perform_later("enqueued inside a rolled back transaction")
          raise ActiveRecord::Rollback
        end
      end
    end

    job = SolidQueue::Job.last
    assert_equal "enqueued inside a rolled back transaction", job.arguments.dig("arguments", 0)
  end

  private
    def assert_ready(&block)
      assert_job_counts(ready: 1, &block)
      assert SolidQueue::Job.last.ready?
    end

    def assert_scheduled(&block)
      assert_job_counts(scheduled: 1, &block)
      assert SolidQueue::Job.last.scheduled?
    end

    def assert_blocked(&block)
      assert_job_counts(blocked: 1, &block)
      assert SolidQueue::Job.last.blocked?
    end

    def assert_job_counts(ready: 0, scheduled: 0, blocked: 0, &block)
      assert_difference -> { SolidQueue::Job.count }, +(ready + scheduled + blocked) do
        assert_difference -> { SolidQueue::ReadyExecution.count }, +ready do
          assert_difference -> { SolidQueue::ScheduledExecution.count }, +scheduled do
            assert_difference -> { SolidQueue::BlockedExecution.count }, +blocked, &block
          end
        end
      end
    end
end
