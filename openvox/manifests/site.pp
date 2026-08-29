# OpenVox migration - entrypoint. Real agent-managed hosts get a node
# block here; nas/wd-mycloud have no agent at all and are driven by exec
# resources declared on nuc's own node block instead (see
# modules/role/manifests/nuc.pp).
#
# Per-host variance (previously literal class{} args here) lives in
# data/nodes/<certname>.yaml, and each node just includes one role::*
# class - see docs/OPENVOX_BACKLOG.md for the roles/profiles layering
# this replaced flat inline node blocks with.

node 'mljr.tail33930.ts.net' {
  include role::mljr
}

node 'nuc.tail33930.ts.net' {
  include role::nuc
}

node 'ugreen.tail33930.ts.net' {
  include role::ugreen
}
