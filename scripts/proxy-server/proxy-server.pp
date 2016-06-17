Exec { path => [ "/bin/", "/sbin/" ] }

vcsrepo {"/opt/stack/tripleo-ci":
    source => "https://github.com/derekhiggins/tripleo-ci.git",
    provider => git,
    ensure => latest,
}

cron {"refresh-server":
    command => "timeout 20m puppet apply /opt/stack/tripleo-ci/scripts/te-broker/te-broker.pp",
    minute  => "*/30"
}

package{"squid": } ->
file {"/etc/squid/squid.conf":
    source => "/opt/stack/tripleo-ci/scripts/proxy-server/squid.conf",
} ~>
service {"squid":
    ensure => "running",
}

