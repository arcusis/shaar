<!-- This Source Code Form is subject to the terms of the Mozilla Public
     License, v. 2.0. If a copy of the MPL was not distributed with this
     file, You can obtain one at https://mozilla.org/MPL/2.0/. -->
<script>
  export let id;
  export let initial;
  let count = initial;
</script>
<button {id} on:click={() => count++}>Child count: {count}</button>
