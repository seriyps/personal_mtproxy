DESTDIR:=
prefix:=$(DESTDIR)/opt
REBAR3:=rebar3
SERVICE:=$(DESTDIR)/etc/systemd/system/personal_mtproxy.service
BACKUP_SERVICE:=$(DESTDIR)/etc/systemd/system/personal-mtproxy-dets-backup.service
BACKUP_TIMER:=$(DESTDIR)/etc/systemd/system/personal-mtproxy-dets-backup.timer
LOGDIR:=$(DESTDIR)/var/log/personal_mtproxy
DATADIR:=$(DESTDIR)/var/lib/personal_mtproxy
USER:=personal_mtproxy

CERTBOT_HOOK_DIR  := $(DESTDIR)/etc/letsencrypt/renewal-hooks/deploy
CERTBOT_HOOK_DEST := $(CERTBOT_HOOK_DIR)/personal_mtproxy.sh
CERTBOT_HOOK_SRC  := config/certbot-deploy.sh
BACKUP_SCRIPT_SRC := config/backup-dets.sh
BACKUP_SCRIPT_DEST := $(prefix)/personal_mtproxy/bin/backup-dets.sh

# Read all vhost domains from config/sys.config.
# Matches lines like:  domain   => "some.domain.tld",
DOMAINS := $(shell awk -F'"' '/domain[[:space:]]*=>/{print $$2}' config/sys.config 2>/dev/null)

DEV_CERT_DIR := priv/certs
DEV_CERT     := $(DEV_CERT_DIR)/cert.pem
DEV_KEY      := $(DEV_CERT_DIR)/key.pem
DEV_DOMAIN   := demo.personal-mtp.test

all: config/sys.config config/vm.args
	$(REBAR3) as prod release

.PHONY: test
test:
	$(REBAR3) ct

config/sys.config: config/sys.config.example
	[ -f $@ ] || cp $^ $@

config/vm.args: config/vm.args.example
	[ -f $@ ] || cp $^ $@

.PHONY: dev-certs
dev-certs: $(DEV_CERT)

$(DEV_CERT):
	mkdir -p $(DEV_CERT_DIR)
	openssl req -x509 -newkey rsa:2048 -keyout $(DEV_KEY) -out $(DEV_CERT) \
	  -days 3650 -nodes \
	  -subj "/CN=$(DEV_DOMAIN)" \
	  -addext "subjectAltName=DNS:$(DEV_DOMAIN)"

.PHONY: dev-hosts
dev-hosts:
	grep -qF "$(DEV_DOMAIN)" /etc/hosts || \
	  echo "127.0.0.1 $(DEV_DOMAIN)  # personal_mtproxy dev" | sudo tee -a /etc/hosts

.PHONY: dev
dev: dev-certs dev-hosts
	$(REBAR3) as dev shell --config config/local.sys.config

.PHONY: clean
clean:
	sudo sed -i "/# personal_mtproxy dev$$/d" /etc/hosts
	rm -rf $(DEV_CERT_DIR)
	$(REBAR3) clean

user:
	sudo useradd -r $(USER) || true

$(LOGDIR):
	mkdir -p $(LOGDIR)/
	chown $(USER) $(LOGDIR)/

$(DATADIR):
	mkdir -p $(DATADIR)/
	chown $(USER) $(DATADIR)/

install: user $(LOGDIR) $(DATADIR)
	mkdir -p $(prefix)
	cp -r _build/prod/rel/personal_mtproxy $(prefix)/
	mkdir -p $(prefix)/personal_mtproxy/log/
	chmod 777 $(prefix)/personal_mtproxy/log/
	install -D config/personal-mtproxy.service $(SERVICE)
	install -D config/personal-mtproxy-dets-backup.service $(BACKUP_SERVICE)
	install -D config/personal-mtproxy-dets-backup.timer $(BACKUP_TIMER)
	install -D -m 755 $(BACKUP_SCRIPT_SRC) $(BACKUP_SCRIPT_DEST)
	systemctl daemon-reload
	# --- Per-vhost cert directories and certbot deploy hook ---
	@test -n "$(DOMAINS)" || \
	  (echo "ERROR: no vhost domains found in config/sys.config" >&2; exit 1)
	install -D -m 755 $(CERTBOT_HOOK_SRC) $(CERTBOT_HOOK_DEST)
	@for domain in $(DOMAINS); do \
	  domaindir="$(DATADIR)/$$domain"; \
	  mkdir -p "$$domaindir"; \
	  chown $(USER) "$$domaindir"; \
	  ln -sfn /etc/letsencrypt/live/$$domain "$$domaindir/cert-lineage"; \
	  echo "Configured vhost: $$domain -> $$domaindir/"; \
	  if [ -r /etc/letsencrypt/live/$$domain/privkey.pem ]; then \
	    echo "  Certificate found — running deploy hook to copy certs..."; \
	    RENEWED_LINEAGE=/etc/letsencrypt/live/$$domain bash $(CERTBOT_HOOK_DEST); \
	  else \
	    echo ""; \
	    echo "  WARNING: No certificate found at /etc/letsencrypt/live/$$domain/"; \
	    echo "    Generate one first (see README), then start the service."; \
	    echo ""; \
	  fi \
	done

.PHONY: migrate-vhosts-certs
migrate-vhosts-certs:
	@old_link="$(DATADIR)/cert-lineage"; \
	if [ ! -L "$$old_link" ]; then \
	  echo "Nothing to migrate: $$old_link not found (already migrated or never installed)."; \
	  exit 0; \
	fi; \
	lineage=$$(readlink "$$old_link"); \
	domain=$$(basename "$$lineage"); \
	domaindir="$(DATADIR)/$$domain"; \
	echo "Migrating cert layout for domain: $$domain"; \
	mkdir -p "$$domaindir"; \
	chown $(USER) "$$domaindir"; \
	for f in fullchain.pem privkey.pem; do \
	  if [ -f "$(DATADIR)/$$f" ]; then \
	    mv "$(DATADIR)/$$f" "$$domaindir/$$f"; \
	    echo "  Moved $(DATADIR)/$$f -> $$domaindir/$$f"; \
	  else \
	    echo "  WARNING: $(DATADIR)/$$f not found, skipping."; \
	  fi; \
	done; \
	ln -sfn "$$lineage" "$$domaindir/cert-lineage"; \
	echo "  Created $$domaindir/cert-lineage -> $$lineage"; \
	rm "$$old_link"; \
	echo "  Removed old $$old_link"; \
	echo "Migration complete. Update sys.config to use new paths:"; \
	echo "  ssl_cert => $$domaindir/fullchain.pem"; \
	echo "  ssl_key  => $$domaindir/privkey.pem"


update-sysconfig: config/sys.config $(prefix)/personal_mtproxy
	REL_VSN=$$(cat $(prefix)/personal_mtproxy/releases/start_erl.data | cut -d " " -f 2) && \
		install -m 644 config/sys.config "$(prefix)/personal_mtproxy/releases/$${REL_VSN}/sys.config"

uninstall:
	rm $(SERVICE)
	rm -f $(BACKUP_SERVICE) $(BACKUP_TIMER)
	rm -r $(prefix)/personal_mtproxy
	rm -f $(CERTBOT_HOOK_DEST)
	systemctl daemon-reload
