# Homebrew formula for the vault-bridge-agent.
#
# Live tap lives at podmaker/homebrew-tap (separate repo). This
# copy is the source-of-truth that the CI release workflow copies
# into the tap repo on every `bridge-v*` tag — see
# .github/workflows/release-vault-bridge.yml.
#
# After a release tag the URL + sha256 lines are rewritten so
# `brew install podmaker/tap/podmaker-vault-bridge` pulls the new
# binary verbatim. The dev placeholders below intentionally fail
# checksum verification — they are overwritten by CI.
class PodMakerVaultBridge < Formula
  desc "PodMaker vault-bridge agent — outbound proxy from a customer network to the SaaS control plane"
  homepage "https://podmaker.sh/docs/vault-bridge"
  version "0.0.0-dev"
  license "MIT"

  # CI rewrites the four lines below on every release tag.
  on_macos do
    on_intel do
      url "https://github.com/podmaker/podmaker/releases/download/bridge-v#{version}/podmaker-vault-bridge-darwin-amd64.tar.gz"
      sha256 "REPLACE_WITH_DARWIN_AMD64_SHA256"
    end
    on_arm do
      url "https://github.com/podmaker/podmaker/releases/download/bridge-v#{version}/podmaker-vault-bridge-darwin-arm64.tar.gz"
      sha256 "REPLACE_WITH_DARWIN_ARM64_SHA256"
    end
  end

  on_linux do
    on_intel do
      url "https://github.com/podmaker/podmaker/releases/download/bridge-v#{version}/podmaker-vault-bridge-linux-amd64.tar.gz"
      sha256 "REPLACE_WITH_LINUX_AMD64_SHA256"
    end
    on_arm do
      url "https://github.com/podmaker/podmaker/releases/download/bridge-v#{version}/podmaker-vault-bridge-linux-arm64.tar.gz"
      sha256 "REPLACE_WITH_LINUX_ARM64_SHA256"
    end
  end

  def install
    # Tarball ships the platform-tagged binary; rename on the way in.
    plat = case
           when OS.mac? && Hardware::CPU.intel? then "darwin-amd64"
           when OS.mac? && Hardware::CPU.arm?   then "darwin-arm64"
           when OS.linux? && Hardware::CPU.intel? then "linux-amd64"
           when OS.linux? && Hardware::CPU.arm? then "linux-arm64"
           else raise "unsupported platform"
           end
    bin.install "podmaker-vault-bridge-#{plat}" => "podmaker-vault-bridge"
  end

  service do
    run [opt_bin/"podmaker-vault-bridge"]
    environment_variables PODMAKER_BRIDGE_CERT_DIR: "#{Dir.home}/.podmaker-bridge"
    keep_alive true
    log_path  var/"log/podmaker-vault-bridge.log"
    error_log_path var/"log/podmaker-vault-bridge.err"
    working_dir Dir.home
  end

  test do
    # No PODMAKER_BRIDGE_ID set — the agent should print its
    # banner + bail out with the required-env message.
    output = shell_output("#{bin}/podmaker-vault-bridge 2>&1", 1)
    assert_match "vault-bridge-agent starting", output
    assert_match "PODMAKER_BRIDGE_ID", output
  end
end
