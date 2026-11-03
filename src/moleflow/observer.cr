require "json"

module Moleflow
  # Immutable physical progress, independent of live-read delivery. A terminal
  # snapshot has an end_reason; it can be shorter than total_samples on eject.
  record ReadProgress, read_id : String, channel : Int32, samples : Int64,
    total_samples : Int64, sample_rate : Int32, end_reason : String = "" do
    include JSON::Serializable
  end

  # Optional application observation. Callbacks run on the simulation's
  # coordinator, never on signal workers. Consumers own filtering/throttling
  # and should return promptly. These observations must not drive Read Until.
  abstract class Observer
    def on_progress(progress : ReadProgress) : Nil
    end

    # All recording writes have completed before this callback runs.
    def on_recording_closed(directory : String) : Nil
    end

    def observe(progress : Array(ReadProgress)) : Nil
      progress.each { |read| on_progress(read) }
    end
  end
end
