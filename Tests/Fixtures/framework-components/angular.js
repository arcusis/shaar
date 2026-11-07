(function () {
  const root = document.createElement("app-root");
  root.id = "angular-app";
  root.setAttribute("ng-version", "18.2.0");
  const header = document.createElement("app-header");
  header.id = "angular-header";
  header.textContent = "Local";
  const counter = document.createElement("app-counter");
  counter.id = "angular-counter";
  counter.textContent = "2";
  root.appendChild(header);
  root.appendChild(counter);
  document.body.appendChild(root);

  function component(name, inputs, state) {
    return { constructor: { [name]: function () {} }[name], inputs: inputs, state: state };
  }
  const components = new Map([
    [root, component("App", {}, { ready: true })],
    [header, component("Header", { title: "Local" }, {})],
    [counter, component("Counter", { start: 0 }, { count: 2 })],
  ]);
  window.ng = {
    getComponent: function (element) { return components.get(element) || null; },
  };
  window.getAllAngularRootElements = function () { return [root]; };
})();
