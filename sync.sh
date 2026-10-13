#!/usr/bin/env bash
set +H   # matikan history expansion: aman meski dijalankan dalam mode interaktif (klik dua kali)
# ==========================================
# SINKRONISASI GIT: tarik → commit → push (HANYA branch main)
# - Memastikan pekerjaan berada di branch main; bila tidak, menawarkan pindah / ganti nama.
# - Menarik commit terbaru dari GitHub (rebase, perubahan lokal diamankan otomatis).
# - Commit perubahan lokal setelah diperiksa dari file rahasia.
# - Push ke main, termasuk commit lama yang belum terkirim.
# Simpan file ini dengan akhir baris LF (bukan CRLF) agar bisa dijalankan Git Bash.
# ==========================================
set -Eeuo pipefail

REMOTE="${REMOTE:-origin}"
readonly BRANCH="main"   # satu-satunya branch yang disinkronkan
REMOTE_EXISTS=0
MAX_FILE_MB=50   # GitHub menolak file > 100 MB dan memperingatkan file > 50 MB

# ==========================================
# UTILITAS
# ==========================================
log_error() { printf '❌ [%s] %s\n' "$1" "$2" >&2; }

on_exit() {
  local code=$?
  if [[ -t 0 ]]; then
    echo
    read -r -p "Tekan Enter untuk keluar..." _ || true
  fi
  exit "$code"
}
trap on_exit EXIT
trap 'log_error "BARIS $LINENO" "Perintah gagal (kode $?)."' ERR

confirm() {
  local answer=""
  read -r -p "$1 (y/N): " answer || return 1
  [[ "${answer,,}" =~ ^(y|ya|yes)$ ]]
}

remote_ref() { echo "refs/remotes/${REMOTE}/${BRANCH}"; }

# ==========================================
# VALIDASI REPOSITORY
# ==========================================
check_repository() {
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log_error "REPOSITORY" "Folder ini belum menjadi repository Git."
    exit 1
  fi
  cd "$(git rev-parse --show-toplevel)"

  if ! git remote get-url "$REMOTE" >/dev/null 2>&1; then
    log_error "REMOTE" "Remote '$REMOTE' belum dikonfigurasi."
    echo "Tambahkan dengan: git remote add $REMOTE <URL_REPOSITORY_GITHUB>"
    exit 1
  fi

  if [[ -d "$(git rev-parse --git-path rebase-merge)" || -d "$(git rev-parse --git-path rebase-apply)" ]]; then
    log_error "REBASE" "Masih ada proses rebase yang belum selesai."
    echo "Selesaikan dengan 'git rebase --continue' atau batalkan dengan 'git rebase --abort'."
    exit 1
  fi
  if [[ -f "$(git rev-parse --git-path MERGE_HEAD)" ]]; then
    log_error "MERGE" "Masih ada proses merge yang belum selesai."
    echo "Selesaikan dengan 'git commit' atau batalkan dengan 'git merge --abort'."
    exit 1
  fi

  ensure_main_branch

  echo "📂 Repository : $(basename "$PWD")"
  echo "🌿 Branch     : $BRANCH"
  echo "🔗 Remote     : $REMOTE ($(git remote get-url "$REMOTE"))"
}

# ==========================================
# PASTIKAN BEKERJA DI BRANCH main
# ==========================================
ensure_main_branch() {
  local current choice="" has_local_main=0 has_remote_main=0
  current="$(git branch --show-current)"

  if [[ -z "$current" ]]; then
    log_error "BRANCH" "HEAD dalam kondisi detached. Jalankan: git switch $BRANCH"
    exit 1
  fi
  [[ "$current" == "$BRANCH" ]] && return 0

  echo
  echo "⚠️ Branch aktif adalah '$current', sedangkan skrip ini hanya menyinkronkan '$BRANCH'."

  # Belum ada commit sama sekali: cukup ganti nama, tanpa risiko apa pun.
  if ! git rev-parse --verify --quiet HEAD >/dev/null; then
    git symbolic-ref HEAD "refs/heads/$BRANCH"
    echo "✅ Branch kosong '$current' diganti nama menjadi '$BRANCH'."
    return 0
  fi

  git show-ref --verify --quiet "refs/heads/$BRANCH" && has_local_main=1
  git fetch --quiet "$REMOTE" 2>/dev/null || true
  git show-ref --verify --quiet "refs/remotes/$REMOTE/$BRANCH" && has_remote_main=1

  if (( has_local_main )); then
    # main sudah ada di lokal: pindah saja; commit di branch ini tidak disentuh.
    echo "  1. Pindah ke branch '$BRANCH'  (commit di '$current' tetap tersimpan di branch itu)"
  else
    echo "  1. Ganti nama branch '$current' menjadi '$BRANCH'  - pekerjaan ini menjadi main"
    if (( has_remote_main )); then
      echo "  2. Ambil '$BRANCH' dari GitHub dan pindah ke sana  (commit di '$current' tidak dikirim)"
    fi
  fi
  echo "  0. Batal"
  read -r -p "Pilih: " choice || true

  case "$choice" in
    1)
      if (( has_local_main )); then
        if ! git switch "$BRANCH"; then
          log_error "BRANCH" "Gagal pindah: perubahan yang belum di-commit bentrok dengan '$BRANCH'."
          echo "Commit dulu perubahan di '$current', atau simpan dengan: git stash"
          exit 1
        fi
        echo "ℹ️ Commit di '$current' tidak ikut dikirim. Gabungkan bila perlu: git merge $current"
      else
        git branch -m "$current" "$BRANCH"
        git branch --unset-upstream >/dev/null 2>&1 || true
        echo "✅ Branch '$current' sekarang bernama '$BRANCH'."
      fi ;;
    2)
      if (( has_local_main == 1 || has_remote_main == 0 )); then
        echo "⏹️ Pilihan tidak tersedia. Dibatalkan."; exit 1
      fi
      if ! git switch -c "$BRANCH" --track "$REMOTE/$BRANCH"; then
        log_error "BRANCH" "Gagal pindah: ada file lokal yang bentrok dengan isi '$BRANCH' di GitHub."
        exit 1
      fi
      echo "ℹ️ Commit di '$current' tidak ikut dikirim dan tetap tersimpan di branch itu." ;;
    *)
      echo "⏹️ Dibatalkan. Tidak ada yang diubah."
      exit 1 ;;
  esac
  echo "🌿 Sekarang di branch '$BRANCH'."
}

# ==========================================
# PENGATURAN FETCH & RIWAYAT DANGKAL (bekas "git clone --depth 1")
# ==========================================
# Clone --depth 1 / --single-branch membatasi fetch ke satu branch. Bila branch itu tidak ada
# di repo tujuan, fetch gagal dengan "couldn't find remote ref". Kembalikan ke pengaturan standar.
fix_fetch_refspec() {
  local want="+refs/heads/*:refs/remotes/$REMOTE/*" current
  current="$(git config --get-all "remote.$REMOTE.fetch" || true)"
  grep -qxF "$want" <<< "$current" && return 0
  echo "🔧 Pengaturan fetch hanya mengambil: ${current:-(kosong)}"
  echo "   (biasanya bekas clone --depth 1). Diubah agar mengambil semua branch."
  git config --replace-all "remote.$REMOTE.fetch" "$want"
}

is_shallow() { [[ "$(git rev-parse --is-shallow-repository 2>/dev/null)" == "true" ]]; }

# Riwayat dangkal tidak bisa di-push ke repo lain (GitHub: "shallow update not allowed").
handle_shallow() {
  is_shallow || return 0
  local choice="" src="" msg new
  echo
  echo "⚠️ Riwayat repo ini dangkal (hasil salinan --depth 1): commit lamanya tidak ikut tersalin."
  echo "   GitHub menolak push dari riwayat seperti ini ke repo lain."
  if (( REMOTE_EXISTS == 0 )); then
    echo "  1. Jadikan isi saat ini sebagai commit awal yang baru  - disarankan untuk salinan situs"
  fi
  echo "  2. Lengkapi riwayat dari repo asal (butuh URL repo yang dulu disalin)"
  echo "  0. Batal"
  read -r -p "Pilih: " choice || true

  case "$choice" in
    1)
      if (( REMOTE_EXISTS == 1 )); then echo "⏹️ Pilihan tidak tersedia."; exit 1; fi
      msg="Salinan awal $(basename "$PWD") ($(date '+%d/%m/%Y'))"
      new="$(git commit-tree "HEAD^{tree}" -m "$msg")" || { log_error "RIWAYAT" "Gagal membuat commit awal."; exit 1; }
      git update-ref -m "riwayat baru dari salinan dangkal" "refs/heads/$BRANCH" "$new"
      # Bersihkan sisa riwayat dangkal agar repo kembali normal.
      git reflog expire --expire-unreachable=now --all >/dev/null 2>&1 || true
      git gc --prune=now --quiet >/dev/null 2>&1 || true
      echo "✅ Riwayat baru dibuat: 1 commit berisi semua file saat ini ('$msg')."
      ;;
    2)
      read -r -p "URL repo asal (mis. https://github.com/pemilik/dekeku.git): " src || true
      [[ -n "$src" ]] || { echo "⏹️ Dibatalkan."; exit 1; }
      echo "📥 Mengambil riwayat lengkap dari repo asal..."
      if ! git fetch --unshallow "$src"; then
        log_error "UNSHALLOW" "Riwayat tidak bisa diambil dari $src. Periksa URL dan aksesnya."
        exit 1
      fi
      echo "✅ Riwayat lengkap sudah diambil."
      ;;
    *)
      echo "⏹️ Dibatalkan. Tidak ada yang dikirim."
      exit 1 ;;
  esac
}

# ==========================================
# TARIK PERUBAHAN DARI GITHUB
# ==========================================
sync_remote() {
  echo
  fix_fetch_refspec
  echo "🌐 Mengambil informasi terbaru dari GitHub..."
  if ! git fetch --prune "$REMOTE"; then
    log_error "FETCH" "Gagal menghubungi remote. Periksa koneksi, URL, dan autentikasi."
    echo "Untuk mencari penyebabnya, jalankan: bash cek-koneksi-git.sh"
    exit 1
  fi

  if ! git show-ref --verify --quiet "$(remote_ref)"; then
    REMOTE_EXISTS=0
    local others
    others="$(git for-each-ref --format='%(refname:strip=3)' "refs/remotes/$REMOTE" | grep -v '^HEAD$' | paste -sd ' ' - || true)"
    if [[ -z "$others" ]]; then
      echo "🆕 Repo GitHub masih kosong; branch '$BRANCH' akan dibuat saat push."
      return 0
    fi
    # GitHub punya branch lain (mis. master) tetapi tidak punya main.
    echo
    echo "⚠️ GitHub tidak punya branch '$BRANCH', tetapi punya: $others"
    echo "   Bila dilanjutkan, '$BRANCH' dibuat sebagai branch BARU di samping branch itu."
    echo "   Situs GitHub Pages dan branch default GitHub tetap memakai branch lama,"
    echo "   sehingga perubahan Anda belum tentu tayang."
    echo
    echo "   Disarankan: ganti nama branch default di GitHub menjadi '$BRANCH'"
    echo "   (repo → Settings → General → Default branch → ikon pensil), lalu jalankan ulang skrip ini."
    if ! confirm "Tetap buat branch '$BRANCH' baru di GitHub?"; then
      echo "⏹️ Dibatalkan. Tidak ada yang dikirim."
      exit 1
    fi
    return 0
  fi
  REMOTE_EXISTS=1

  # Lokal belum punya commit: ambil isi main dari GitHub sebagai titik awal.
  if ! git rev-parse --verify --quiet HEAD >/dev/null; then
    echo "📥 Folder lokal belum punya commit; mengambil isi '$BRANCH' dari GitHub..."
    if ! git checkout -q -B "$BRANCH" --track "$REMOTE/$BRANCH"; then
      log_error "CHECKOUT" "Ada file lokal yang bentrok dengan isi GitHub. Pindahkan file itu dulu, lalu ulangi."
      exit 1
    fi
    echo "✅ Isi GitHub sudah diambil; file lokal lain tetap ada dan bisa di-commit."
    return 0
  fi

  if ! git merge-base HEAD "$REMOTE/$BRANCH" >/dev/null 2>&1; then
    echo "⚠️ Riwayat lokal dan GitHub dimulai dari commit awal yang berbeda"
    echo "   (biasanya karena repo GitHub dibuat dengan README / lisensi)."
    if ! confirm "Susun commit lokal di atas riwayat GitHub lalu lanjutkan?"; then
      log_error "HISTORY" "Dibatalkan. Tidak ada yang diubah."
      exit 1
    fi
    rebase_or_explain
    return 0
  fi

  local ahead behind
  read -r ahead behind <<< "$(git rev-list --left-right --count "HEAD...$REMOTE/$BRANCH")"
  echo "Commit lokal belum terkirim : $ahead"
  echo "Commit baru di GitHub       : $behind"

  if (( behind == 0 )); then
    echo "✅ Tidak ada commit baru di GitHub."
    return 0
  fi

  rebase_or_explain
}

# Rebase ke $REMOTE/$BRANCH; bila konflik, jelaskan cara menyelesaikan lalu berhenti.
rebase_or_explain() {
  echo "📥 Menerapkan commit dari GitHub (rebase)..."
  # Data sudah di-fetch; rebase langsung tanpa menghubungi jaringan lagi.
  if ! git rebase --autostash "$REMOTE/$BRANCH"; then
    log_error "REBASE" "Ada konflik saat menggabungkan perubahan."
    echo
    git status --short || true
    echo
    echo "Cara menyelesaikan:"
    echo "  1. Buka file bertanda konflik (<<<<<<< ======= >>>>>>>) lalu perbaiki."
    echo "  2. git add <file>"
    echo "  3. git rebase --continue"
    echo "Untuk membatalkan dan kembali ke kondisi semula: git rebase --abort"
    echo "Bila perubahan belum di-commit tidak kembali, cek: git stash list"
    exit 1
  fi
  echo "✅ Perubahan dari GitHub sudah diterapkan."
}

# ==========================================
# PEMERIKSAAN KEAMANAN SEBELUM COMMIT
# ==========================================
# Mengembalikan 1 bila ada file rahasia / token / file terlalu besar di staging.
check_staged_safety() {
  local problems=0 f size

  # 1. Nama file yang tidak boleh masuk repository.
  while IFS= read -r f; do
    case "${f##*/}" in
      .dev.vars | .env | .env.* | *.pem | *.key | *.p12 | *.pfx | id_rsa* | credentials*.json | *service-account*.json)
        [[ "${f##*/}" == *.example ]] && continue
        log_error "RAHASIA" "File sensitif ikut di-stage: $f"
        problems=1 ;;
    esac
  done < <(git diff --cached --name-only --diff-filter=AM)

  # 2. Isi yang menyerupai token atau private key (hanya baris yang ditambahkan).
  local hits
  hits="$(git diff --cached -U0 --diff-filter=AM \
    | grep -nE '^\+.*(ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|gho_[A-Za-z0-9]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|AKIA[0-9A-Z]{16})' \
    | cut -c1-120 || true)"
  if [[ -n "$hits" ]]; then
    log_error "RAHASIA" "Ditemukan teks yang menyerupai token/private key:"
    echo "$hits" | sed 's/\(ghp_\|github_pat_\|gho_\)[A-Za-z0-9_]\{4\}[A-Za-z0-9_]*/\1****/g'
    problems=1
  fi

  # 3. File terlalu besar untuk GitHub.
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    size=$(( $(wc -c < "$f") / 1024 / 1024 ))
    if (( size >= MAX_FILE_MB )); then
      log_error "UKURAN" "$f berukuran ${size} MB; GitHub menolak file di atas 100 MB."
      problems=1
    fi
  done < <(git diff --cached --name-only --diff-filter=AM)

  return "$problems"
}

# ==========================================
# COMMIT
# ==========================================
commit_changes() {
  echo
  if [[ -z "$(git status --porcelain)" ]]; then
    echo "📦 Tidak ada perubahan file lokal."
    return 0
  fi

  echo "📝 Perubahan lokal:"
  git status --short
  echo
  if ! confirm "Commit semua perubahan di atas?"; then
    echo "⏹️ Commit dilewati."
    return 0
  fi

  git add -A
  if git diff --cached --quiet; then
    echo "ℹ️ Tidak ada perubahan yang dapat di-commit."
    return 0
  fi

  if ! check_staged_safety; then
    git reset -q   # kembalikan staging; file di folder tidak diubah
    echo
    echo "⛔ Commit dibatalkan demi keamanan. Tidak ada yang dikirim."
    echo "   Tambahkan file rahasia ke .gitignore, atau hapus token dari kodenya,"
    echo "   lalu jalankan ulang skrip ini."
    exit 1
  fi

  local message="" default
  default="Auto-sync $(date '+%H:%M %d/%m/%Y')"
  read -r -p "Pesan commit [$default]: " message || true
  message="${message:-$default}"

  if ! git commit -q -m "$message"; then
    log_error "COMMIT" "Commit gagal. Periksa pesan error di atas."
    exit 1
  fi
  echo "✅ Commit dibuat: $message"
}

# ==========================================
# PUSH
# ==========================================
push_changes() {
  local ahead=0
  if ! git rev-parse --verify --quiet HEAD >/dev/null; then
    echo "ℹ️ Belum ada commit di '$BRANCH'; tidak ada yang dikirim."
    return 0
  fi
  handle_shallow

  if (( REMOTE_EXISTS )); then
    ahead="$(git rev-list --count "$REMOTE/$BRANCH..HEAD")"
    if (( ahead == 0 )); then
      echo "✅ GitHub sudah sama dengan lokal; tidak ada yang perlu di-push."
      return 0
    fi
    echo
    echo "🚀 Mengirim $ahead commit ke GitHub..."
  else
    echo
    echo "🚀 Membuat branch '$BRANCH' di GitHub dan mengirim commit..."
  fi

  # -u: atur upstream agar 'git push' / 'git pull' biasa juga langsung bekerja.
  if git push -u "$REMOTE" "$BRANCH"; then
    echo "✅ Push berhasil."
    return 0
  fi

  # Push ditolak biasanya karena ada commit baru di GitHub sejak fetch tadi: coba sekali lagi.
  echo "⚠️ Push ditolak. Menarik perubahan terbaru lalu mencoba sekali lagi..."
  sync_remote
  if git push -u "$REMOTE" "$BRANCH"; then
    echo "✅ Push berhasil pada percobaan kedua."
    return 0
  fi

  log_error "PUSH" "Push gagal."
  echo "Coba jalankan manual:"
  echo "  git fetch $REMOTE"
  echo "  git rebase $REMOTE/$BRANCH"
  echo "  git push -u $REMOTE $BRANCH"
  exit 1
}

# ==========================================
# EKSEKUSI UTAMA
# ==========================================
main() {
  echo "🚀 Memulai sinkronisasi Git..."
  check_repository
  sync_remote
  commit_changes
  push_changes
  echo
  echo "✅ Proses selesai."
}

main