//! The parts of a PIM role-management policy that affect self-activation.
//! Azure remains the authority: this is used to fill in defaults and to ask
//! for input up front, never to bypass server-side validation.
pub const Policy = struct {
    /// Longest activation allowed, if the policy caps it.
    max_duration_min: ?u32 = null,
    justification_required: bool = false,
    ticket_required: bool = false,
    mfa_required: bool = false,
    approval_required: bool = false,
    /// Conditional Access authentication context the activation requires.
    auth_context: ?[]const u8 = null,
};
