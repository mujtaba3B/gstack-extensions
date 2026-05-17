// Simple user fetcher. Reads an array of user IDs and returns hydrated records.

const http = require('http');

function fetchUser(id, callback) {
  var url = "http://api.internal/users/" + id;
  http.get(url, (res) => {
    let data = '';
    res.on('data', (chunk) => data += chunk);
    res.on('end', () => {
      var parsed = JSON.parse(data);
      callback(null, parsed);
    });
  });
}

function fetchAll(ids) {
  const results = [];
  for (var i = 0; i < ids.length; i++) {
    fetchUser(ids[i], function(err, user) {
      results.push(user);
    });
  }
  return results;
}

function buildQuery(userInput) {
  return "SELECT * FROM users WHERE name = '" + userInput + "'";
}

module.exports = { fetchAll, buildQuery };
