(function () {
  const mount = document.createElement("div");
  mount.id = "react-app";
  const header = document.createElement("h1");
  header.id = "react-header";
  header.textContent = "Local";
  const counter = document.createElement("button");
  counter.id = "react-counter";
  counter.textContent = "2";
  mount.appendChild(header);
  mount.appendChild(counter);
  document.body.appendChild(mount);

  function App() {}
  App.displayName = "App";
  function Header() {}
  Header.displayName = "Header";
  function Counter() {}
  Counter.displayName = "Counter";

  const counterFiber = {
    type: Counter,
    key: null,
    memoizedProps: { start: 0, children: "2" },
    memoizedState: {
      memoizedState: 2,
      next: { memoizedState: { tag: 5, create: function () {}, deps: [] }, next: null },
    },
    stateNode: counter,
    child: null,
    sibling: null,
  };
  const headerFiber = {
    type: Header,
    key: "title",
    memoizedProps: { title: "Local" },
    memoizedState: null,
    stateNode: header,
    child: null,
    sibling: counterFiber,
  };
  const appFiber = {
    type: App,
    key: null,
    memoizedProps: { title: "Local" },
    memoizedState: { memoizedState: true, next: null },
    stateNode: mount,
    child: headerFiber,
    sibling: null,
  };
  const root = { current: { child: appFiber, stateNode: mount } };
  mount["__reactContainer$fixture"] = root;
  const roots = new Set([root]);
  window.__REACT_DEVTOOLS_GLOBAL_HOOK__ = {
    renderers: new Map([[1, { version: "18.3.1" }]]),
    getFiberRoots: function (id) { return id === 1 ? roots : new Set(); },
  };
})();
