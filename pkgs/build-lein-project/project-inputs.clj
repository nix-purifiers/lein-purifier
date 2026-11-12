;; SPDX-License-Identifier: MIT
;; Loaded by Leiningen's native user init hook, before it reads project.clj.
(require '[clojure.edn :as edn]
         '[leiningen.core.project :as project])

(let [configuration (System/getenv "LEIN_PURIFIER_PROVIDED_CONFIG")
      overrides (get-in (edn/read-string (slurp configuration))
                        [:aliases :nix-purifier-project-inputs :override-deps])
      canonical (fn [library]
                  (if (namespace library)
                    library
                    (symbol (name library) (name library))))
      select-coordinate (fn [coordinate]
                          (if (and (vector? coordinate) (symbol? (first coordinate)))
                            (if-let [selected (get overrides (canonical (first coordinate)))]
                              (assoc coordinate 1 (:mvn/version selected))
                              coordinate)
                            coordinate))
      select-project (fn select-project [model]
                       (if (map? model)
                         (let [selected (reduce (fn [model field]
                                                  (if (contains? model field)
                                                    (update model field #(with-meta (mapv select-coordinate %) (meta %)))
                                                    model))
                                                model [:dependencies :managed-dependencies :plugins])
                               managed (into {} (map (fn [coordinate]
                                                     [(canonical (first coordinate)) coordinate]))
                                             (:managed-dependencies selected))
                               forced (reduce-kv (fn [result library coordinate]
                                                   (assoc result library [library (:mvn/version coordinate)]))
                                                 managed overrides)]
                           (cond-> (assoc selected :managed-dependencies (mapv val (sort-by (comp str key) forced)))
                             (:profiles selected) (update :profiles #(into (empty %) (map (fn [[name profile]]
                                                                                         [name (select-project profile)])) %))))
                         model))]
  (alter-var-root #'project/init-project
                  (fn [original]
                    (fn [model & arguments]
                      (select-project (apply original (select-project model) arguments)))))
  ;; Tasks such as pom and uberjar reselect profiles after initialization.
  ;; Keep the same selected coordinates when they do so.
  (alter-var-root #'project/set-profiles
                  (fn [original]
                    (fn [model & arguments]
                      (select-project (apply original (select-project model) arguments))))))
