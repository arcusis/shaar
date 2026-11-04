CREATE TABLE history_items(id INTEGER PRIMARY KEY, url TEXT, title TEXT);
CREATE TABLE history_visits(id INTEGER PRIMARY KEY, history_item INTEGER, visit_time REAL);
INSERT INTO history_items VALUES(1, 'https://safari-history.example.test/', 'Safari history');
INSERT INTO history_visits VALUES(1, 1, 700000000.0);
INSERT INTO history_visits VALUES(2, 1, -1.0);
