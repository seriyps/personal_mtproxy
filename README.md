## Personal MTProto Proxy Demo

Demo app: [mtproto_proxy](https://github.com/seriyps/mtproto_proxy) + Cowboy + personal domain registration UI.

Users visit a web page, optionally enter their email, and receive a personal
MTProto proxy link tied to a unique subdomain. Subdomains are persisted in DETS
and restored into the policy table on restart. See [DNS setup](#dns-setup-production)
for the required wildcard DNS records that enable per-user server routing.

[Article](priv/ARTICLE.md)

![WEB UI](priv/ui-screenshot.png)

## Local development

It requires Erlang 25+ installed! On Ubuntu: `sudo apt install erlang-nox erlang-dev`.

```bash
# Start shell with self-signed certs + /etc/hosts entry auto-configured
make dev

# Cleanup: removes /etc/hosts entry, certs, and compiled beams
make clean
```

Then open https://demo.personal-mtp.test:2443/ in your browser
(accept the self-signed cert warning).

The MTP proxy itself listens on port 2443 in local mode (no root required).

## DNS setup (production)

Two records are required (replace `proxy.example.com` with your domain and `1.2.3.4` with your server's IP):

| Name | Type | Value |
|------|------|-------|
| `proxy.example.com` | A | `1.2.3.4` |
| `*.proxy.example.com` | A | `1.2.3.4` |

The wildcard record covers all personal subdomains (`alice42.proxy.example.com`, etc.).
Each generated proxy link uses the full subdomain as the server hostname — the fake-TLS
SNI encodes the subdomain too, so the TCP hostname and the SNI always match.
In a multi-server setup you can later point individual subdomains to different servers
via more specific A records, enabling per-user geographic routing without changing the
proxy software.

## Production build & install

```bash
# Install Erlang
sudo apt install erlang-nox erlang-dev

# Copy and edit configs
cp config/sys.config.example config/sys.config
cp config/vm.args.example config/vm.args
$EDITOR config/sys.config   # set base_domain, cert paths, real secret

# Build release
make
```
> Generate TLS certificate BEFORE starting the service (see [TLS certificate](#tls-certificate-production) section below)!

```bash
# Install to /opt/personal_mtproxy + systemd unit
sudo make install
sudo systemctl enable --now personal_mtproxy personal-mtproxy-dets-backup.timer
```

The backup timer creates a timestamped copy of
`/var/lib/personal_mtproxy/proxies.dets` in the same directory once per day,
for example `proxies.dets.20260411T231559Z.bak`, and keeps only the 10 newest
backups.

## TLS certificate (production)

Single-domain cert via certbot (HTTP-01 challenge, no DNS required):

```bash
certbot certonly --standalone -d demo.personal-mtp.online
```

Wildcard cert (`*.demo.personal-mtp.online`) requires DNS-01 — see [article](priv/ARTICLE.md) for details.

## Split-mode setup (front + back)

`mtproto_proxy` supports running the client-facing part (front) on a domestic
server and the Telegram-facing part (back) on a foreign server. See the
[mtproto_proxy README](https://github.com/seriyps/mtproto_proxy#split-mode-setup-front--back)
for the full setup guide, firewall rules, and inter-server link options.

`personal_mtproxy` can run on the **back node** — which is the right choice for
multi-front deployments, because DETS (the user database) then lives in one
place and is the single source of truth. On every front reconnect the back
replays the full subdomain list into that front's policy table automatically.

**Front nodes** run vanilla `mtproto_proxy` (no `personal_mtproxy`). Use
`config/sys.config.front.example` from the mtproto_proxy repo as a starting
point — the key settings are:

```erlang
{mtproto_proxy, [
  {node_role, front},
  {back_node, 'back@<BACK_IP>'},   % must match -name in back node's vm.args
  {ports, [#{name => mtp_handler_1, listen_ip => "0.0.0.0", port => 443,
             secret => <<"...same secret as back...">>,
             tag => <<"...">>}]},
  {allowed_protocols, [mtp_fake_tls]},
  {domain_fronting, "<BACK_IP>:8443"},  % forward non-MTP to Cowboy on back node
  {policy, [{in_table, tls_domain, personal_domains},
            {max_connections, [tls_domain], 100}]}
]}
```

**Back node `sys.config` additions:**

```erlang
{mtproto_proxy, [
  {node_role, back},
  %% personal_mtproxy reads port + secret from here to build proxy links.
  %% mtproto_proxy itself ignores `ports` on a back node.
  {ports, [#{name => mtp_handler_1, listen_ip => "0.0.0.0", port => 443,
             secret => <<"...same secret as fronts...">>,
             tag => <<"...">>}]},
  ...
]},
{personal_mtproxy, [
  %% domain_fronting is not available on a back node; explicit addr is required.
  {web_listen_ip,   "0.0.0.0"},
  {web_listen_port, 8443},
  ...
]}
```

To manually resync all connected front nodes (e.g. after split-brain recovery):

```bash
/opt/personal_mtproxy/bin/personal_mtproxy eval 'pm_registry:refresh_fronts().'
```
