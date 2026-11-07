(function () {
  const mount = document.createElement("section");
  mount.id = "vue-app";
  const header = document.createElement("h1");
  header.id = "vue-header";
  header.textContent = "Local";
  const counter = document.createElement("button");
  counter.id = "vue-counter";
  counter.textContent = "2";
  mount.appendChild(header);
  mount.appendChild(counter);
  document.body.appendChild(mount);

  const headerInstance = {
    type: { name: "Header" },
    props: { title: "Local" },
    setupState: {},
    subTree: { el: header, children: [] },
  };
  const counterInstance = {
    type: { name: "Counter" },
    props: { start: 0 },
    setupState: { count: 2 },
    subTree: { el: counter, children: null },
  };
  const app = {
    type: { name: "App" },
    props: { title: "Local" },
    setupState: { ready: true },
    subTree: {
      el: mount,
      children: [{ component: headerInstance }, { component: counterInstance }],
    },
  };
  mount.__vue_app__ = { _instance: app };
})();
