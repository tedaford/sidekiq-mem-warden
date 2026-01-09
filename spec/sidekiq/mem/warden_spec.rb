require "spec_helper"

RSpec.describe Sidekiq::Mem::Warden do
  let(:sidekiq_process_set) { instance_double(Sidekiq::ProcessSet) }
  let(:sidekiq_process) { instance_double(Sidekiq::Process) }

  before do
    allow(subject).to receive(:warn)
    allow(subject).to receive(:sleep)
    allow(sidekiq_process).to receive(:quiet!)
    allow(sidekiq_process).to receive(:stop!)
    allow(sidekiq_process).to receive(:stopping?)
  end

  describe "#sidekiq_process" do
    let(:identity) { "foobar" }
    let(:mock_processes) do
      [{
        "identity" => identity,
        "tag" => "baz",
        "started_at" => Time.now,
        "concurrency" => 5,
        "busy" => 2,
        "queues" => %w[low medium high]
      }]
    end

    it "finds the process by identity" do
      if subject.respond_to?(:config=)
        subject.config = mock_processes.first
      else
        allow(subject).to receive(:identity).and_return(identity)
      end

      allow(Sidekiq).to receive(:redis)
      sidekiq_process_set = Sidekiq::ProcessSet.new
      sidekiq_mock_processes = mock_processes.map { |mock_process| Sidekiq::Process.new(mock_process) }
      allow(sidekiq_process_set).to receive(:each) { |&block| sidekiq_mock_processes.each(&block) }
      allow(Sidekiq::ProcessSet).to receive(:new).and_return(sidekiq_process_set)

      expect(subject.send(:identity)).to eq(identity)
      expect(subject.send(:sidekiq_process)).to be_a(Sidekiq::Process)
      expect(subject.send(:sidekiq_process).identity).to eq(identity)
    end
  end

  context "with stubbed sidekiq_process" do
    before do
      allow(Sidekiq::ProcessSet).to receive(:new) { sidekiq_process_set }
      allow(sidekiq_process_set).to receive(:find) { sidekiq_process }
      identity = "some-identity"
      if subject.respond_to?(:config=)
        subject.config = { "identity" => identity }
      else
        allow(subject).to receive(:identity).and_return(identity)
      end
    end

    describe "#call" do
      let(:worker) { double("worker") }
      let(:job) { double("job") }
      let(:queue) { double("queue") }

      it "yields to the chain" do
        expect { |b| subject.call(worker, job, queue, &b) }.to yield_with_no_args
      end

      context "when current rss is over max rss" do
        subject { described_class.new(max_rss: 2) }

        before do
          allow(subject).to receive(:current_rss).and_return(3)
        end

        it "requests shutdown" do
          expect(subject).to receive(:request_shutdown)
          subject.call(worker, job, queue) {}
        end

        it "runs garbage collection" do
          allow(subject).to receive(:request_shutdown)
          expect(GC).to receive(:start).with(full_mark: true, immediate_sweep: true)
          subject.call(worker, job, queue) {}
        end

        context "and skip_shutdown_if is given" do
          subject { described_class.new(max_rss: 2, skip_shutdown_if: skip_shutdown_proc) }

          context "when skip_shutdown_if returns true" do
            let(:skip_shutdown_proc) { proc { |worker, job, queue| true } }
            it "does not request shutdown" do
              expect(subject).not_to receive(:request_shutdown)
              subject.call(worker, job, queue) {}
            end
          end

          context "when skip_shutdown_if returns false" do
            let(:skip_shutdown_proc) { proc { |worker, job, queue| false } }
            it "still requests shutdown" do
              expect(subject).to receive(:request_shutdown)
              subject.call(worker, job, queue) {}
            end
          end
        end

        context "and on_shutdown is given" do
          subject { described_class.new(max_rss: 2, on_shutdown: on_shutdown_proc) }

          let(:on_shutdown_proc) { proc { |worker, job, queue| nil } }

          it "executes on_shutdown hook" do
            expect(subject).to receive(:request_shutdown).once
            expect(on_shutdown_proc).to receive(:call).once
            subject.call(worker, job, queue) {}
          end
        end

        context "when gc is false" do
          subject { described_class.new(max_rss: 2, gc: false) }
          it "does not call garbage collect" do
            allow(subject).to receive(:request_shutdown)
            expect(GC).not_to receive(:start)
            subject.call(worker, job, queue) {}
          end
        end

        context "but max rss is 0" do
          subject { described_class.new(max_rss: 0) }
          it "does not request shutdown" do
            expect(subject).not_to receive(:request_shutdown)
            subject.call(worker, job, queue) {}
          end
        end
      end
    end

    describe "#request_shutdown" do
      context "with default grace time" do
        before { allow(subject).to receive(:shutdown) { sleep 0.01 } }
        it "calls shutdown" do
          expect(subject).to receive(:shutdown)
          subject.send(:request_shutdown).join
        end
        it "does not call shutdown twice when called concurrently" do
          expect(subject).to receive(:shutdown).once
          2.times.map { subject.send(:request_shutdown) }.each(&:join)
        end
      end

      context "with a 5 second grace time" do
        subject { described_class.new(max_rss: 2, grace_time: 5.0, shutdown_wait: 0) }
        it "waits the specified grace time before stopping" do
          allow(subject).to receive(:jobs_finished?).and_return(false)

          shutdown_request_time = nil
          shutdown_time = nil

          original_request_shutdown = subject.method(:request_shutdown)
          allow(subject).to receive(:request_shutdown) do
            shutdown_request_time = Time.now
            original_request_shutdown.call
          end

          expect(sidekiq_process).to receive(:stop!) do
            shutdown_time = Time.now
          end

          allow(Process).to receive(:kill)
          allow(Process).to receive(:pid).and_return(99)

          subject.send(:request_shutdown).join

          elapsed_time = shutdown_time - shutdown_request_time
          expect(elapsed_time).to be >= 5.0
        end
      end

      context "with infinite grace time" do
        subject { described_class.new(max_rss: 2, grace_time: Float::INFINITY, shutdown_wait: 0) }
        it "only stops after jobs finish" do
          allow(subject).to receive(:jobs_finished?).and_return(true)
          allow(Process).to receive(:pid).and_return(99)
          expect(sidekiq_process).to receive(:quiet!)
          expect(sidekiq_process).to receive(:stop!)
          expect(Process).to receive(:kill).with("SIGKILL", 99)

          subject.send(:request_shutdown).join
        end
      end
    end
  end
end
