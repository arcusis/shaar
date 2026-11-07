# Live coverage collection

Opening the Coverage panel asks the page once. Collection turns on when the page accepts `Profiler.enable`, precise coverage, and CSS rule-usage tracking. A rejected command leaves Start disabled. A page that goes away mid-probe can be asked again.

shaar.21 accepts precise coverage only after the profiler domain is enabled. `Profiler.enable` is not in that allowlist, so a hidden panel probe reports `Profiler is not enabled` and records no script row. Patch `0046-shaar-devtools-profiler-enable.patch` adds developer command 81. The live row is not proven until the next engine build includes that patch.

Start still records detailed ranges with call counts off, then enables CSS and starts rule tracking. Stop takes the script ranges, stops both trackers, and lists each script and style sheet.

Related: [[Engine_Module_devtools]], [[Shaar_DevTools_Panel_Stream]].
