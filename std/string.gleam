pub fn concat(strings: List(String)) -> String {
  case strings {
    ListCons(head, rest) -> head <> concat(rest)
    ListEmpty -> ""
  }
}

pub fn join(strings: List(String), separator: String) -> String {
  case strings {
    ListCons(head, rest) -> head <> join_rest(rest, separator)
    ListEmpty -> ""
  }
}

fn join_rest(strings: List(String), separator: String) -> String {
  case strings {
    ListCons(head, rest) -> separator <> head <> join_rest(rest, separator)
    ListEmpty -> ""
  }
}
