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
const ROLLOUT_COUNT_LIMIT = 100000000

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
/// Called after the current quota is proved insufficient with external use
/// fixed. Increasing the cap only adds creation edges, so lower caps can
/// be ruled out together. An exhausted search is not proof of infeasibility.
fn minimum_rollout_quota(
  policy : RollPolicy,
  initial : RollState,
) -> (Int32, Array[String])? {
  let fixed = policy.fixed_other + initial.other_retiring
  let final_occupancy = fixed + policy.replicas
  // Every state uses at most all initially present old Pods and the target
  // number of new Pods, even if none of the old slots have been released.
  let mut high = minimum(
    ROLLOUT_COUNT_LIMIT,
    final_occupancy + initial.old + initial.retiring,
  )
  let mut low = if policy.hard >= final_occupancy {
    policy.hard + 1
  } else {
    final_occupancy
  }
  let mut witness = None
  while low <= high {
    let cap = low + (high - low) / 2
    match rollout_search({ ..policy, hard: cap, }, initial, false) {
      Path(path) => {
        witness = Some((cap, path))
        high = cap - 1
      }
      Blocked(_, _) => low = cap + 1
      SearchLimit => return None
    }
  }
  witness
}

///|
/// Keep quota and external occupancy fixed. Try budgets in order because a
/// larger budget changes how many old replicas the controller retires at once.
fn minimum_rollout_unavailability(
  policy : RollPolicy,
  initial : RollState,
) -> Result[(Int32, Array[String]), String] {
  let final_occupancy = policy.fixed_other +
    initial.other_retiring +
    policy.replicas
  if final_occupancy > policy.hard {
    return Err(
      "固定配额下无法仅靠放宽 maxUnavailable 完成替换，完成态需要 \{final_occupancy} 个名额，生效上限为 \{policy.hard}",
    )
  }
  let last = minimum(policy.replicas, policy.unavailable + 16)
  for candidate in (policy.unavailable + 1)..<(last + 1) {
    match
      rollout_search({ ..policy, unavailable: candidate, }, initial, false) {
      Path(path) => return Ok((candidate, path))
      Blocked(_, _) => ()
      SearchLimit =>
        return Err(
          "最小 maxUnavailable 未判定，路径搜索达到状态上限",
        )
    }
  }
  if last < policy.replicas {
    Err(
      "最小 maxUnavailable 未判定，已检查当前值以上的 16 个候选值",
    )
  } else {
    Err("固定配额下无法仅靠放宽 maxUnavailable 完成替换")
  }
}

///|
fn minimum(a : Int32, b : Int32) -> Int32 {
  if a < b {
    a
  } else {
    b
  }
}
