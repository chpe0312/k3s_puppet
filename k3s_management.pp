# @summary K3s installieren, joinen und updaten - alles via Hiera gesteuert
#
# Diese Klasse macht je nach Zustand automatisch das Richtige:
#
#   1. Erster Run, bootstrap=true   -> K3s installieren, Cluster initialisieren
#   2. Erster Run, bootstrap=false  -> K3s installieren, Cluster joinen
#   3. Folgende Runs, gleiche Version -> nichts tun (idempotent)
#   4. Folgende Runs, neue Version  -> K3s upgraden, Service neu starten
#
# Steuerung komplett ueber Hiera 
# nur bootstrap/node_ip/server_url.
#
# @param version      K3s-Version, z.B. 'v1.33.10+k3s1' (https://github.com/k3s-io/k3s/releases)
# @param token        Cluster-Token 
# @param bootstrap    true auf genau einem Node, false auf den anderen
# @param node_ip      IP dieses Nodes im Cluster-Netz
# @param tls_sans     Zusaetzliche TLS-SANs (alle Server-IPs + spaetere VIP)
# @param flannel_iface Interface fuer das Flannel-Overlay
# @param server_url   Bei bootstrap=false: URL des Bootstrap-Nodes (https://<ip>:6443)
#
class k3s_management (
  String[1]                  $version,
  String[1]                  $token,
  Boolean                    $bootstrap,
  Stdlib::IP::Address        $node_ip,
  Array[Stdlib::IP::Address] $tls_sans,
  String[1]                  $flannel_iface,
  Optional[Stdlib::HTTPSUrl] $server_url = undef,
) {
  if !$bootstrap and !$server_url {
    fail('server_url muss gesetzt sein, wenn bootstrap=false')
  }
 
  ensure_resource('file', ['/etc/rancher', '/etc/rancher/k3s'], { 'ensure' => 'directory' })
 
  # === config.yaml ===
  # Token landet hier (mode 0600), nicht im exec-Command -> kein Leak in ps/Logs.
  file { '/etc/rancher/k3s/config.yaml':
    ensure    => file,
    owner     => 'root',
    group     => 'root',
    mode      => '0600',
    show_diff => false,
    content   => epp('k3s/config.yaml.epp', {
        'token'      => $token,
        'node_ip'    => $node_ip,
        'tls_sans'   => $tls_sans,
        'iface'      => $flannel_iface,
        'bootstrap'  => $bootstrap,
        'server_url' => $server_url,
    }),
    notify    => Exec['k3s-install'],
  }
 
  # === Installer-Skript cachen ===
  exec { 'fetch-k3s-installer':
    command => '/usr/bin/curl -sfL https://get.k3s.io -o /usr/local/bin/k3s-install.sh && /bin/chmod +x /usr/local/bin/k3s-install.sh',
    creates => '/usr/local/bin/k3s-install.sh',
    path    => '/usr/bin:/bin',
  }
 
  # === Install / Join / Update ===
  # Marker-Datei traegt die installierte Version. Bei Hiera-Aenderung von
  # $version schlaegt der unless-Check fehl -> Installer laeuft erneut
  # und tauscht das Binary aus. Beim allerersten Run existiert die Datei
  # nicht -> Installer laeuft -> K3s wird installiert (bootstrap oder join,
  # je nach config.yaml).
  $marker = '/var/lib/rancher/k3s/.installed_version'
 
  exec { 'k3s-install':
    command   => "/bin/sh -c 'INSTALL_K3S_VERSION=${version} INSTALL_K3S_EXEC=server INSTALL_K3S_SKIP_START=true INSTALL_K3S_SKIP_ENABLE=true /usr/local/bin/k3s-install.sh && mkdir -p $(dirname ${marker}) && echo ${version} > ${marker}'",
    unless    => "/usr/bin/test -f ${marker} && /usr/bin/grep -qFx '${version}' ${marker}",
    timeout   => 600,
    logoutput => 'on_failure',
    require   => [
      Exec['fetch-k3s-installer'],
      File['/etc/rancher/k3s/config.yaml'],
    ],
  }
 
  service { 'k3s':
    ensure    => running,
    enable    => true,
    subscribe => Exec['k3s-install'],
  }
}
 
