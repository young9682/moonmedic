///|
const SNAPSHOT_FIXTURE = "{\"ns\":\"prod\",\"target_kind\":\"Deployment\",\"target_name\":\"payments-api\",\"deployment\":{\"metadata\":{\"name\":\"payments-api\"}},\"replicasets\":[{\"metadata\":{\"name\":\"payments-api-7d9f6b\"}}],\"pods\":[],\"events\":[{\"reason\":\"FailedCreate\"}],\"quotas\":[{\"metadata\":{\"name\":\"compute\"}}],\"limit_ranges\":[],\"logs\":\"boot failed\",\"notes\":[\"events read from namespace\"]}"

///|
test "snapshot parses the fixture format" {
  let snapshot = @snapshot.ClusterSnapshot::from_json(
    @json.parse(SNAPSHOT_FIXTURE),
  ).unwrap()
  inspect(snapshot.ns, content="prod")
  inspect(snapshot.target_kind, content="Deployment")
  inspect(snapshot.target_name, content="payments-api")
  inspect(snapshot.deployment is Some(_), content="true")
  inspect(snapshot.replicasets.length(), content="1")
  inspect(snapshot.events.length(), content="1")
  inspect(snapshot.quotas.length(), content="1")
  inspect(snapshot.logs is Some("boot failed"), content="true")
  inspect(snapshot.notes.length(), content="1")
}

///|
test "snapshot rejects a missing target" {
  let result = @snapshot.ClusterSnapshot::from_json(
    @json.parse("{\"ns\":\"prod\",\"target_kind\":\"Pod\"}"),
  )
  let rejected = match result {
    Ok(_) => false
    Err(_) => true
  }
  inspect(rejected, content="true")
}

///|
test "snapshot JSON round-trips" {
  let first = @snapshot.ClusterSnapshot::from_json(
    @json.parse(SNAPSHOT_FIXTURE),
  ).unwrap()
  let encoded = first.to_json().stringify()
  let second = @snapshot.ClusterSnapshot::from_json(@json.parse(encoded)).unwrap()
  inspect(second.target_kind, content="Deployment")
  inspect(second.target_name, content="payments-api")
  inspect(second.replicasets.length(), content="1")
  inspect(second.notes.length(), content="1")
}

///|
test "data_status labels round-trip and gate usability" {
  let raw = "{\"ns\":\"prod\",\"target_kind\":\"Deployment\",\"target_name\":\"x\",\"replicasets\":[],\"pods\":[],\"events\":[],\"quotas\":[],\"limit_ranges\":[],\"data_status\":{\"replicasets\":{\"state\":\"unavailable\",\"reason\":\"RBAC forbidden\"},\"events\":{\"state\":\"truncated\",\"seen\":37},\"quotas\":\"available\",\"limit_ranges\":\"empty\"}}"
  let snapshot = @snapshot.ClusterSnapshot::from_json(@json.parse(raw)).unwrap()
  match snapshot.replicasets_status {
    Unavailable(reason) => inspect(reason, content="RBAC forbidden")
    other => inspect(other, content="expected Unavailable")
  }
  inspect(snapshot.replicasets_status.is_usable(), content="false")
  match snapshot.events_status {
    Truncated(seen) => inspect(seen, content="37")
    other => inspect(other, content="expected Truncated")
  }
  inspect(snapshot.events_status.is_usable(), content="false")
  inspect(snapshot.quotas_status is Available, content="true")
  inspect(snapshot.limit_ranges_status is Empty, content="true")
  let encoded = snapshot.to_json().stringify()
  inspect(encoded.contains("\"state\":\"unavailable\""), content="true")
  inspect(encoded.contains("\"reason\":\"RBAC forbidden\""), content="true")
}

///|
test "snapshot without data_status defaults by array shape" {
  let raw = "{\"ns\":\"prod\",\"target_kind\":\"Deployment\",\"target_name\":\"x\",\"replicasets\":[],\"pods\":[{\"a\":1}],\"events\":[],\"quotas\":[],\"limit_ranges\":[]}"
  let snapshot = @snapshot.ClusterSnapshot::from_json(@json.parse(raw)).unwrap()
  inspect(snapshot.replicasets_status is Empty, content="true")
  inspect(snapshot.pods_status is Available, content="true")
}

///|
test "unknown data_status label degrades to unavailable" {
  let raw = "{\"ns\":\"prod\",\"target_kind\":\"Deployment\",\"target_name\":\"x\",\"replicasets\":[],\"pods\":[],\"events\":[],\"quotas\":[],\"limit_ranges\":[],\"data_status\":{\"pods\":\"gibberish\"}}"
  let snapshot = @snapshot.ClusterSnapshot::from_json(@json.parse(raw)).unwrap()
  match snapshot.pods_status {
    Unavailable(_) => inspect("unavailable", content="unavailable")
    other => inspect(other, content="expected Unavailable")
  }
}
