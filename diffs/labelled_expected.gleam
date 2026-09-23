import gleam/io
import gleam/set
import gleam/string

type Holder {
  Holder(items: set.Set(Int))
  Pair(left: set.Set(Int), right: set.Set(Int))
}

pub fn main() {
  let holder = Holder(items: set.new())
  io.println(string.inspect(set.size(holder.items)))
  let pair = Pair(left: set.from_list([1, 2]), right: set.new())
  io.println(string.inspect(set.size(pair.left) + set.size(pair.right)))
}
