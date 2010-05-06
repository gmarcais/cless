def assert(msg = "")
  yield or raise "Assert failed: #{msg}"
end
