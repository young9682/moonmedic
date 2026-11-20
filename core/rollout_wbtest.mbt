///|
/// Independent reachability criterion for a healthy initial rollout: the
/// first replacement needs either one unavailable replica or a usable surge
/// slot. After that first replacement, the same exchange can be repeated.
test "healthy starts agree with the first replacement criterion" {
  let mut cases = 0
  for replicas in 1..<6 {
    for surge in 0..<3 {
      for unavailable in 0..<(minimum(2, replicas) + 1) {
        if surge == 0 && unavailable == 0 {
          continue
        }
        for headroom in 0..<2 {
          for draining in 0..<2 {
            let policy = {
              replicas,
              surge,
              unavailable,
              hard: replicas + 1 + headroom,
              fixed_other: 1 - draining,
            }
            let start = {
              old: replicas,
              desired: minimum(surge, replicas),
              live: 0,
              available: 0,
              retiring: 0,
              other_retiring: draining,
            }
            for allow_release in [true, false] {
              let slot = headroom > 0 || (allow_release && draining > 0)
              let possible = unavailable > 0 || (surge > 0 && slot)
              match rollout_search(policy, start, allow_release) {
                Path(_) => assert_true(possible)
                Blocked(_, _) => assert_false(possible)
                SearchLimit => fail("small search exceeded its budget")
              }
            }
            cases = cases + 1
          }
        }
      }
    }
  }
  assert_eq(cases, 148)
}
