import gleam/list
import gleamc/ir
import gleamc/pipeline

fn has_phi(functions: List(ir.Function)) -> Bool {
  list.any(functions, fn(function) {
    let ir.Function(_, _, _, blocks, _) = function
    list.any(blocks, fn(block) {
      let ir.Block(_, ops, _) = block
      list.any(ops, fn(op) {
        case op {
          ir.OpPhi(_, _) -> True
          _ -> False
        }
      })
    })
  })
}

/// A `case` whose arms produce a value joins through an `OpPhi` (the result
/// temporary is no longer a memory slot written by `OpCopy`).
pub fn case_join_phi_test() {
  let source =
    "pub fn main() -> Int {\n  let x = case 1 {\n    1 -> 10\n    _ -> 20\n  }\n  x\n}\n"
  let assert Ok(module) = pipeline.compile_to_ir(source)
  let ir.Module(functions) = module
  assert has_phi(functions)
}
