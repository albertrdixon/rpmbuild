Gem::Specification.new do |s|
  s.name	= 'rpmbuild'
  s.version	= '0.6.6'
  s.date	= '2014-02-10'
  s.summary	= "Create RPMs"
  s.description	= "A wrapper around rpmbuild for generating custom RPMs"
  s.authors	= ["Albert Dixon"]
  s.email	= "adixon415n@gmail.com"
  s.license	= "GPLv3"
  s.files	= ["lib/rpmbuild.rb"]
  s.executables << 'gen_rpm'
  s.add_runtime_dependency 'trollop', '~> 2.0'
  s.add_runtime_dependency 'psych', '~> 2.0.2'
  s.requirements << 'rpmbuild >= 4.8.0'
end
