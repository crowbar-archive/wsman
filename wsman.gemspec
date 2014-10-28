$:.push File.expand_path('../lib', __FILE__)
require 'wsman/version'

Gem::Specification.new do |s|
  s.name        = 'wsman'
  s.version     = Wsman::VERSION
  s.authors     = ['Thomas Boerger', 'David Paterson']
  s.homepage    = 'https://github.com/crowbar/wsman'
  s.license     = 'Apache-2.0'
  s.summary     = 'WS-MAN library'
  s.description = 'WS-MAN communication library'
  s.email       = 'tboerger@suse.de'

  s.files         = `git ls-files`.split($/)
  s.executables   = s.files.grep(%r{^bin/}) { |f| File.basename(f) }
  s.test_files    = s.files.grep(%r{^(test|spec|features)/})
  s.require_paths = ['lib']

  s.post_install_message = File.read('UPGRADING') if File.exists?('UPGRADING')

  s.add_runtime_dependency 'xml-simple', '>= 1.0.0'

  s.add_development_dependency 'bundler'
  s.add_development_dependency 'rake'
  s.add_development_dependency 'yard'
  s.add_development_dependency 'gem-release'
end
