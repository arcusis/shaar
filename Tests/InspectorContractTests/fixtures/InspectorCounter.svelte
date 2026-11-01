<!-- This Source Code Form is subject to the terms of the Mozilla Public
     License, v. 2.0. If a copy of the MPL was not distributed with this
     file, You can obtain one at https://mozilla.org/MPL/2.0/. -->
<script>
  import InspectorChild from './InspectorChild.svelte';
  export let label = 'Svelte counter';
  let count = 4;
</script>
<button id="svelte-counter" on:click={() => count++}>{label}: {count}</button>
<InspectorChild id="svelte-child-one" initial={6}/>
<InspectorChild id="svelte-child-two" initial={7}/>
