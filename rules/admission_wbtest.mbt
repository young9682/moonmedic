///|
test "quota admission checks requested, used and hard for the same resources" {
  let message = "Error creating: pods \"app-x\" is forbidden: exceeded quota: compute, requested: requests.cpu=500m,memory=64Mi, used: requests.cpu=900m,memory=64Mi, limited: requests.cpu=1,memory=100Mi"
  guard classify_admission(message) is QuotaExceeded(rejection) else {
    fail("expected explicit quota rejection")
  }
  inspect(rejection.name, content="compute")
  inspect(rejection.requested.get("requests.cpu") == Some(0.5), content="true")
  inspect(rejection.requested.get("memory") == Some(67108864.0), content="true")
  inspect(
    classify_admission(
      "exceeded quota: compute, requested: pods=1, used: pods=3, limited: pods=10",
    )
    is Unclassified,
    content="true",
  )
  inspect(
    classify_admission(
      "failed quota: compute: must specify limits.cpu,requests.cpu",
    )
    is MissingQuotaResources,
    content="true",
  )
}

///|
test "limit range accepts structured violations and abstains on generic validation" {
  for
    message in [
      "minimum memory usage per Container is 64Mi, but request is 32Mi", "maximum memory usage per Pod is 64Mi.  No limit is specified",
      "memory max limit to request ratio per Container is 2, but provided ratio is 4.000000",
      "[maximum memory usage per Container is 64Mi, but limit is 256Mi, maximum cpu usage per Container is 1, but limit is 2]",
    ] {
    inspect(classify_admission(message) is LimitRangeRejected, content="true")
  }
  for
    message in [
      "Invalid value: unsupported field value", "minimum replica policy", "maximum memory usage per Container is 64Mi, but limit is 32Mi",
      "admission webhook denied the request: maximum memory usage per Container is 64Mi, but limit is 256Mi",
    ] {
    inspect(classify_admission(message) is Unclassified, content="true")
  }
}
