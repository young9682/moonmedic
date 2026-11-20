///|
/// Counts in the restricted two-ReplicaSet model. Old active Pods are available.
#derive(Eq, Hash)
priv struct RollState {
  old : Int32
  desired : Int32
  live : Int32
  available : Int32
  retiring : Int32
  other_retiring : Int32
}

///|
priv struct RollPolicy {
  replicas : Int32
  surge : Int32
  unavailable : Int32
  hard : Int32
  fixed_other : Int32
}

///|
priv enum RollResult {
  Path(Array[String])
  Blocked(Int32, RollState)
  SearchLimit
}

///|
/// Each edge represents one controller, admission, readiness or release step.
/// A parent link produces a shortest witness without storing a path per node.
fn rollout_search(
  p : RollPolicy,
  start : RollState,
  release_other : Bool,
) -> RollResult {
  let states = [start]
  let parents = [(-1, "")]
  let seen : Map[RollState, Bool] = Map([])
  seen[start] = true
  let mut i = 0
  let mut terminal = start
  while i < states.length() {
    let s = states[i]
    if s.available == p.replicas && s.old == 0 && s.retiring == 0 {
      let path = []
      let mut cursor = i
      while cursor != 0 {
        let (parent, action) = parents[cursor]
        path.push(action)
        cursor = parent
      }
      return Path(path.rev())
    }
    if states.length() >= 10000 {
      return SearchLimit
    }
    let mut can_move = false
    fn enqueue(action : String, next : RollState) -> Unit {
      can_move = true
      if !seen.contains(next) {
        seen[next] = true
        states.push(next)
        parents.push((i, action))
      }
    }
    let desired = minimum(p.replicas, p.replicas + p.surge - s.old)
    let down = minimum(
      s.old,
      s.old + s.available - (p.replicas - p.unavailable),
    )
    if desired > s.desired {
      enqueue("scale_new_rs(+\{desired-s.desired})", { ..s, desired, })
    } else if down > 0 {
      enqueue("scale_old_rs(-\{down})", {
        ..s,
        old: s.old - down,
        retiring: s.retiring + down,
      })
    }
    let used = p.fixed_other + s.old + s.retiring + s.live + s.other_retiring
    if s.live < s.desired && used < p.hard {
      enqueue("create_new_pod", { ..s, live: s.live + 1, })
    }
    if s.available < s.live {
      enqueue("new_available", { ..s, available: s.available + 1, })
    }
    if s.retiring > 0 {
      enqueue("release_old_slot", { ..s, retiring: s.retiring - 1, })
    }
    if release_other && s.other_retiring > 0 {
      enqueue("release_other_slot", {
        ..s,
        other_retiring: s.other_retiring - 1,
      })
    }
    if !can_move {
      terminal = s
    }
    i = i + 1
  }
  Blocked(states.length(), terminal)
}

///|
fn minimum(a : Int32, b : Int32) -> Int32 {
  if a < b {
    a
  } else {
    b
  }
}
