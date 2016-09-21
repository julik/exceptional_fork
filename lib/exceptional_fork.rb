module ExceptionalFork
  VERSION = '1.2.1'
  QUIT = "The child process %d has quit or was killed abruptly. No error information could be retrieved".freeze
  ProcessHung = Class.new(StandardError)
  DEFAULT_TIMEOUT = 10
  DEFAULT_ERROR_STATUS = 99
  
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
  #
  # By default, the child process will be expected to complete within DEFAULT_TIMEOUT seconds
  # (scientifically chosen by an Arbitraryometer-Of-Random-Assumptions). If you need to adjust
  # the timeout, pass a different number as the timeout argument. The timeout is going to be
  # excercised using wait2() with the WNOHANG option, so no threads are going to be used and
  # the wait is not going to be blocking. ExceptionFork is going to do a `Thread.pass` to let
  # other threads do work while it waits on the process to complete.
  def fork_and_wait(kill_after_timeout = DEFAULT_TIMEOUT)
    # Redirect the exceptions in the child to the pipe. When we get a non-zero
    # exit code we can read from that pipe to obtain the exception.
    reader, writer = IO.pipe
    
    # Run the block in a forked child
    pid = fork_with_error_output(writer) { yield }
  
    # Wait for the forked process to exit, in a non-blocking fashion
    exit_code = wait_and_capture(pid, kill_after_timeout)
  
    writer.close rescue IOError # Close the writer so that we can read from the reader
    child_error = reader.read # Read the error output
    reader.close rescue IOError # Do not leak pipes since the process might be long-lived
  
    if exit_code.nonzero? # If the process exited uncleanly capture the error
      # If the child gets KILLed then no exception gets written,
      # and no information gets recovered.
      raise ProcessHung.new(QUIT % pid) if (child_error.nil? || child_error.empty?)
      
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
        errors_pipe.close rescue nil
        Process.exit! success # Exit maintaining the status code
      end
    end
  
    # Return the PID of the forked child
    pid
  end
  
  # Wait for a process to quit in a non-blocking fashion, using a
  # preset timeout, and collect (or synthesize) it's exit code value afterwards
  def wait_and_capture(pid, timeout)
    started_waiting_at = Time.now
    status = nil
    signals = [:TERM, :KILL]
    loop do
      # Use wait2 to recover the status without the global variable (we might
      # be threaded), use WNOHANG so that we do not have to block while waiting
      # for the process to complete. If we block (without WNOHANG), MRI will still
      # be able to do other work _but_ we might be waiting indefinitely. If we use
      # a non-blocking option we can supply a timeout and force-quit the process
      # without using the Timeout module (and conversely having an overhead of 1
      # watcher thread per child spawned).
      if wait_res = Process.wait2(pid, Process::WNOHANG | Process::WUNTRACED)
        _, status = wait_res
        return status.exitstatus || DEFAULT_ERROR_STATUS
      else
        # If the process is still busy and didn't quit,
        # we have to undertake Measures. Send progressively
        # harsher signals to the child
        Process.kill(signals.shift, pid) if (Time.now - started_waiting_at) > timeout
        if signals.empty? # If we exhausted our force-quit powers, do a blocking wait. KILL _will_ work.
          _, status = Process.wait2(pid)
          return status.exitstatus || DEFAULT_ERROR_STATUS # For killed processes this will be nil
        end
      end
      Thread.pass
    end
  rescue Errno::ECHILD, Errno::ESRCH, Errno::EPERM => e# The child already quit
    # Assume the process finished correctly. If there was an error, we will discover
    # that from a zero-size output file. There may of course be a thing where the
    # file gets written incompletely and the child crashes but hey - computers!
    return 0
  end
  
  extend self
end