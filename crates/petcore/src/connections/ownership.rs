#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum ManagedConnectorScriptOwnership {
    Missing,
    Owned,
    Foreign,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum ManagedPathState {
    Missing,
    Safe,
    Conflict,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum ManagedInstallationState {
    NotManaged,
    Managed,
    Conflict,
}
