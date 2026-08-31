# VoxBox is distribution-neutral and does not ship Rocky's native yumrepo
# type. This lightweight fixture exists only so catalog specs can compile
# roles that declare the operating system's real resource type.
Puppet::Type.newtype(:yumrepo) do
  @doc = 'Test-only stand-in for the platform yumrepo resource type.'

  newparam(:name, namevar: true)
  newproperty(:descr)
  newproperty(:baseurl)
  newproperty(:repo_gpgcheck)
  newproperty(:gpgcheck)
  newproperty(:enabled)
  newproperty(:gpgkey)
  newproperty(:sslverify)
  newproperty(:sslcacert)
  newproperty(:metadata_expire)
end
