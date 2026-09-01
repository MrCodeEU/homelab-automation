# VoxBox is distribution-neutral and does not ship the platform-native
# ssh_authorized_key type. This fixture only permits catalog specs to compile
# roles that use the real resource type on managed hosts.
Puppet::Type.newtype(:ssh_authorized_key) do
  @doc = 'Test-only stand-in for the platform ssh_authorized_key resource type.'

  ensurable
  newparam(:name, namevar: true)
  newproperty(:user)
  newproperty(:type)
  newproperty(:key)
  newproperty(:options)
  newproperty(:target)
end
