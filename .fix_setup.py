import sys

with open('setup.sh', 'r') as f:
    content = f.read()

old_start = 'if [[ "${AUTO}" == true ]]; then'
old_end = 'add later via .agent/.studio/add_studio.py"'

# Find the block boundaries
idx_start = content.find(old_start)
if idx_start < 0:
    print("NOT FOUND: old block start")
    sys.exit(1)

idx_end = content.find(old_end, idx_start)
if idx_end < 0:
    print("NOT FOUND: old block end")
    sys.exit(1)
idx_end += len(old_end)

old_block = content[idx_start:idx_end]

new_block = """if [[ "${AUTO}" == true ]]; then
	    info "Skipping (use --auto, add studio manually via psql)"
	    return
	  fi

	  echo "  No studios found. Add one now?"
	  read -p "  Studio ID [studio_a]: " STUDIO_ID; STUDIO_ID="${STUDIO_ID:-studio_a}"
	  read -p "  Name [Моя студия]: " STUDIO_NAME; STUDIO_NAME="${STUDIO_NAME:-Моя студия}"
	  read -p "  YClients company ID (optional): " YC_ID
	  read -p "  AMO CRM domain (optional): " AMO_DOMAIN

	  if [[ "${DRY_RUN}" == true ]]; then
	    info "Would insert studio '${STUDIO_ID}' into ops.studios"
	    return
	  fi

	  psql "${DB_URL}" -c "
	    INSERT INTO ops.studios (studio_id, name, yc_company_id, amo_domain, timezone)
	    VALUES ('${STUDIO_ID}', '${STUDIO_NAME}', ${YC_ID:-NULL}, ${AMO_DOMAIN:+"'${AMO_DOMAIN}'"}${AMO_DOMAIN:-NULL}, 'Europe/Moscow')
	  " 2>/dev/null && success "Studio '${STUDIO_ID}' added" || warn "Studio setup failed — add manually via psql"
"""

content = content.replace(old_block, new_block, 1)
with open('setup.sh', 'w') as f:
    f.write(content)
print("OK - replaced successfully")
