require File.expand_path(File.dirname(__FILE__) + '/spec_helper')

describe "ExceptionalFork" do
  it "re-raises the exception from a subprocess" do
    expect(Process).to receive(:fork).and_call_original
    
    pid_of_parent = Process.pid
    begin
      ExceptionalFork.fork_and_wait do
        raise "This is process #{Process.pid} calling"
      end
      expect(false).to eq(true), "This should never be reached"
    rescue RuntimeError => e
      matches = (e.message =~ /This is process (\d+) calling/)
      expect(matches).not_to be_nil
      expect($1).not_to eq(pid_of_parent.to_s)
    end
  end
  
  it 'raises a simple exception upfront' do
    expect(Process).to receive(:fork).and_call_original
    expect {
      ExceptionalFork.fork_and_wait { raise "Explosion! "}
    }.to raise_error(/Explosion/)
  end
  
  it "kills a process that takes too long to terminate" do
    expect(Process).to receive(:fork).and_call_original
    expect {
      ExceptionalFork.fork_and_wait(1) { sleep 20; raise "Should never ever get here" }
    }.to raise_error(ExceptionalFork::ProcessHung)
  end
  
  it "raises a ProcessHung if no exception information can be recovered" do
    expect(Process).to receive(:fork).and_call_original
    
    pid_of_parent = Process.pid
    begin
      Thread.new { sleep 5; `killall -9 ef-test-process` }
      ExceptionalFork.fork_and_wait { $0 = 'ef-test-process'; sleep 100; }
      expect(false).to eq(true), "This should never be reached"
    rescue => e
      matches = (e.message =~ /No error information could be retrieved/)
      expect(matches).not_to be_nil
      expect($1).not_to eq(pid_of_parent.to_s)
    end
  end
end
