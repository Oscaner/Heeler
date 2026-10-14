import HeelerSSH
import Testing

@testable import Heeler

/// Exercises the real connect-time and post-connect mappers (#133), and which
/// herdr `agent.start` refusals the shell-readiness wait resends (#453).
@Suite("HeelerSSH error mapping")
struct HeelerSSHErrorMappingTests {
    /// The two refusals a fresh pane gets while its shell starts, verbatim
    /// from a live herdr 0.9.4 macOS Host: busy while the shell runs its
    /// startup files, then a launch line longer than the terminal's
    /// canonical input limit until the shell's line editor starts.
    @Test func shellReadinessWaitResendsBusyAndCanonicalModeRefusals() {
        #expect(
            HeelerSSHTransport.isShellReadinessRefusal(
                HerdrAPIError(
                    code: "agent_pane_busy",
                    message: "agent target pane w1:pA is not an available shell")))
        #expect(
            HeelerSSHTransport.isShellReadinessRefusal(
                HerdrAPIError(
                    code: "agent_start_input_failed",
                    message: "input contains a 1108-byte line but the terminal is in "
                        + "canonical mode with a 1024-byte limit; wait for the shell "
                        + "prompt and retry")))
    }

    /// herdr 0.9.4's other `agent_start_input_failed` messages are final:
    /// waiting would only hide them. That includes the sibling that also says
    /// "canonical", and the canonical text under another code, which herdr
    /// 0.9.4's `pane.send_input` answers with.
    @Test func shellReadinessWaitLeavesEveryOtherInputFailureFinal() {
        for message in [
            "could not determine canonical input capacity",
            "pty actor closed",
            "Bad file descriptor (os error 9)",
            "no available capacity",
            "channel closed",
        ] {
            #expect(
                !HeelerSSHTransport.isShellReadinessRefusal(
                    HerdrAPIError(code: "agent_start_input_failed", message: message)),
                "\(message)")
        }
        #expect(
            !HeelerSSHTransport.isShellReadinessRefusal(
                HerdrAPIError(
                    code: "pane_send_failed",
                    message: "input contains a 1108-byte line but the terminal is in "
                        + "canonical mode with a 1024-byte limit; wait for the shell "
                        + "prompt and retry")))
    }

    @Test func connectAndOperationMappersAgreeOnForwardingDenied() {
        let error = SSHError.forwardingDenied
        #expect(
            HeelerSSHTransport.mapConnectForTesting(error)
                == .tcpForwardingUnavailable)
        #expect(
            HeelerSSHTransport.mapOperationForTesting(error)
                == .tcpForwardingUnavailable)
    }

    @Test func connectAndOperationMappersAgreeOnAuthTimeoutAndCancel() {
        #expect(
            HeelerSSHTransport.mapConnectForTesting(SSHError.authenticationFailed)
                == .authenticationFailed)
        #expect(
            HeelerSSHTransport.mapOperationForTesting(SSHError.authenticationFailed)
                == .authenticationFailed)

        #expect(HeelerSSHTransport.mapConnectForTesting(SSHError.timedOut) == .timedOut)
        #expect(HeelerSSHTransport.mapOperationForTesting(SSHError.timedOut) == .timedOut)

        #expect(HeelerSSHTransport.mapConnectForTesting(SSHError.cancelled) == .cancelled)
        #expect(HeelerSSHTransport.mapOperationForTesting(SSHError.cancelled) == .cancelled)
    }

    @Test func pathSpecificMappersStillDivergeWhereIntended() {
        // Connect treats a dead connection as unreachable; operations treat it
        // as a reusable-connection loss with its own copy.
        #expect(
            HeelerSSHTransport.mapConnectForTesting(SSHError.connectionInvalidated)
                == .sshUnreachable(detail: String(describing: SSHError.connectionInvalidated)))
        #expect(
            HeelerSSHTransport.mapOperationForTesting(SSHError.connectionInvalidated)
                == .sshUnreachable(detail: "The SSH connection is no longer reusable."))

        // Generic channel failure is the same classification on both paths.
        #expect(
            HeelerSSHTransport.mapConnectForTesting(SSHError.channelFailed)
                == .channelFailed(detail: String(describing: SSHError.channelFailed)))
        #expect(
            HeelerSSHTransport.mapOperationForTesting(SSHError.channelFailed)
                == .channelFailed(detail: String(describing: SSHError.channelFailed)))
    }
}
