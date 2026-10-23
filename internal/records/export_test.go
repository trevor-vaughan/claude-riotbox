package records

// ReadNoFollow exposes the single guarded open and read of SessionProjects,
// so specs can exercise the defences the Lstat check normally hides.
var ReadNoFollow = readNoFollow
