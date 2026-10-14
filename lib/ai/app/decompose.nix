# Every registered shared surface is either handled by the runtime record or
# diagnosed. Policy may improve a reason, but never gates this coverage.
{lib}: {
  appRecord,
  message,
  present,
  reasonFor,
  sharedSurfaces,
}: let
  runtime = appRecord.name;
  unsupported = lib.subtractLists (appRecord.supportedPools or []) sharedSurfaces;
  warning = surface: let
    path = ["ai" surface];
    explicitReason = reasonFor path;
    reason =
      if explicitReason != null
      then explicitReason
      else "${runtime}'s supportedPools excludes ${surface}; its runtime record does not consume this shared surface.";
  in
    lib.optional (present path)
    (message path reason);
in
  lib.concatMap warning unsupported
