# Shaar DevTools Hebrew and RTL

Shaar DevTools chrome follows the selected launch language, including in its separate window. Hebrew mirrors panel navigation and controls. Code, URLs, JSON values, storage fields, console output, and the DOM tree keep left-to-right reading order inside the RTL interface. Source names such as Browser, Server, and Spotlight use the Shell catalog like other visible controls.

`HebrewPanelsTests` checks dynamic Console labels and responsive tab labels against the Hebrew Shell catalog. `HebrewDevToolsVisualTests` renders the Inspector baseline, every DevTools tab, and Dev Mode offscreen in both appearances without changing the key window. Populated Console, Network, and DOM views use test transports; captures prove app-side presentation and do not verify native engine behavior or live page data.

Related: [[Shaar_Inspector]], [[Hebrew_Localization]], [[Engine_Module_devtools]].
