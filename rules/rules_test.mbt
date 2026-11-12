///|
/// Fixture: pod in CrashLoopBackOff, previous termination was OOMKilled.
const OOMKILL_POD = "{\"metadata\":{\"name\":\"payments-api-7d9f6b-x2k9l\",\"namespace\":\"prod\"},\"spec\":{\"containers\":[{\"resources\":{\"limits\":{\"memory\":\"256Mi\"}}}]},\"status\":{\"phase\":\"Running\",\"containerStatuses\":[{\"restartCount\":12,\"state\":{\"waiting\":{\"reason\":\"CrashLoopBackOff\"}},\"lastState\":{\"terminated\":{\"reason\":\"OOMKilled\",\"exitCode\":137}}}]}}"

///|
/// Fixture: pod pending, scheduler reports insufficient memory.
const PENDING_POD = "{\"metadata\":{\"name\":\"worker-5f8a\",\"namespace\":\"batch\"},\"spec\":{\"containers\":[{\"resources\":{}}]},\"status\":{\"phase\":\"Pending\",\"containerStatuses\":[]}}"

///|
test "oomkilled_limit fires on OOMKilled pod" {
  let raw = @json.parse(OOMKILL_POD)
  let facts = PodFacts::from_pod(raw, events=[])
  let findings = run_all(facts)
  inspect(findings.length(), content="1")
  inspect(findings[0].rule_id, content="oomkilled_limit")
  inspect(facts.restarts, content="12")
  inspect(facts.mem_limit is Some("256Mi"), content="true")
  inspect(findings[0].evidence.length(), content="4")
}

///|
test "sched_insufficient fires with FailedScheduling event" {
  let raw = @json.parse(PENDING_POD)
  let events = [
    "FailedScheduling: 0/6 nodes are available: insufficient memory.",
  ]
  let facts = PodFacts::from_pod(raw, events~)
  let findings = run_all(facts)
  inspect(findings.length(), content="1")
  inspect(findings[0].rule_id, content="sched_insufficient")
  inspect(findings[0].confidence == 0.85, content="true")
}

///|
test "healthy pod produces no findings" {
  let raw = @json.parse(
    "{\"metadata\":{\"name\":\"ok\",\"namespace\":\"x\"},\"status\":{\"phase\":\"Running\",\"containerStatuses\":[{\"restartCount\":0,\"state\":{\"running\":{}}}]}}",
  )
  let facts = PodFacts::from_pod(raw, events=[])
  inspect(run_all(facts).length(), content="0")
  inspect(facts.phase, content="Running")
}

///|
test "crash loop with non-oom exit 137 does not fire oom or crash_exit_1" {
  let raw = @json.parse(
    "{\"metadata\":{\"name\":\"a\",\"namespace\":\"x\"},\"status\":{\"phase\":\"Running\",\"containerStatuses\":[{\"restartCount\":3,\"state\":{\"waiting\":{\"reason\":\"CrashLoopBackOff\"}},\"lastState\":{\"terminated\":{\"reason\":\"Error\",\"exitCode\":137}}}]}}",
  )
  let facts = PodFacts::from_pod(raw, events=[])
  inspect(run_all(facts).length(), content="0")
}
