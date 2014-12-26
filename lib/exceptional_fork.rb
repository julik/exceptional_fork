module ExceptionalFork
  VERSION = '1.0.0'
  
  # Fork with a block and wait until the forked child exits.
  # Any exceptions raised within the block will be re-raised from this
  # in the parent process (where you call it from).
  #
  #   ExceptionalFork.fork_and_wait { raise "Explosion! "} # raises a RuntimeError
  #
  # or for something that runs longer:
  #
  #   ExceptionalFork.fork_and_wait do
  #     perform_long_running_job! # this raises some EOFError or another
  #   end
  #   #=> EOFError... # more data and the backtrace.
  #
  # It is not guaranteed that all the exception metadata will be reinstated due to
  # marshaling/unmarshaling mechanics, but it helps debugging nevertheless.
  def fork_and_wait
    # Redirect the exceptions in the child to the pipe. When we get a non-zero
    # exit code we can read from that pipe to obtain the exception.
    reader, writer = IO.pipe
    
    # Run the block in a forked child
    pid = fork_with_error_output(writer) { yield }
  
    # Wait for the forked process to exit
    Process.wait(pid)
  
    writer.close rescue IOError # Close the writer so that we can read from the reader
    child_error = reader.read # Read the error output
    reader.close rescue IOError # Do not leak pipes since the process might be long-lived
  
    if $?.exitstatus != 0 # If the process exited uncleanly capture the error
      unmarshaled_error, backtrace_in_child = Marshal.load(child_error)
      # Pick up the exception 
      reconstructed_error = unmarshaled_error.exception
      
      # Reconstruct the backtrace
      if reconstructed_error.respond_to?(:set_backtrace)
        reconstructed_error.set_backtrace(backtrace_in_child)
      end
      
      raise reconstructed_error # ..and re-raise it in this (parent) process
    end
  end
  
  def fork_with_error_output(errors_pipe)
    pid = Process.fork do
      # Tracking if the op failed
      success = false
      begin
        # Run the closure passed to the fork_with_error_output method
        yield
        success = true
      rescue Exception => exception
        # Write a YAML dump of the exception and the backtrace to the error
        # pipe, so that we can re-raise it in the parent process ;-)
        error_payload = [exception, exception.backtrace.to_a]
        errors_pipe.puts(Marshal.dump(error_payload))
        errors_pipe.flush
      ensure
        Process.exit! success # Exit maintaining the status code
      end
    end
  
    # Return the PID of the forked child
    pid
  end
  
  extend self
end