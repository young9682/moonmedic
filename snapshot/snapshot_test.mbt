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
