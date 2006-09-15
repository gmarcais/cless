require 'test/unit'
require 'stringio'
require 'cless'

class TestMappedStream < Test::Unit::TestCase
  def test_index
    stream = StringIO.new(<<EOS)
12345
6789
0123456789
abcdefghijklmnop
qrstuv
EOS
    str = stream.string
    MappedStream.new(stream, :buf_size => 20) { |ms|
      assert_equal(str.index("3"), ms.index("3"))
      p "assert1"
      assert_equal(str.index("3", 10), ms.index("3", 10))
      p "assert1"
      assert_equal(str.index("a"), ms.index("a"))
      p "assert1"
      assert_equal(nil, ms.index("z"))
      p "assert1"
      assert_equal(str.index("v"), ms.index("v"))
    }
  end
end

