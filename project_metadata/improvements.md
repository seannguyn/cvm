
1. In repository: container-vulnerability-exemption-tf In move all terraform related things into container-vulnerability-exemption-tf/terraform

2. Your test is currently using actual configuration in unikube. Is that a good thing? Test should be isolated right? what if users change config, or cluster is deleted, then your test will fail. Why you're so amateur?

3. Why is schema_version required for each cluster file? it should follow the same convention as container-vulnerability-exemption-tf_version. per env or per cluster pin.

4. The the script you run in container-vulnerability-exemption/scripts, the argument should be: env/cluster. For example: python3 scripts/render.py --cluster dev/anp07 # --cluster make sense? you decide. the point is the environment information should be there.

5. Also: container-vulnerability-exemption/scripts, schemas, tests, README.md only relate to exemption/unikube. So organise these things accordingly for best practice and extensibility.

6. For local-tf.sh, also make sure 4. is satisfied. Make the script execution cleaner:
  - set all the variable: ENV, CLUSTER, VARS_FILE, STATE_FILE, ENGINE_DIR which is by default $HOME/Dev/container-vulnerability-exemption-tf/terraform unless specified otherwise.
  - VARS_FILE = ENGINE_DIR/out/vars/ENV_CLUSTER.auto.tfvars.json
  - STATE_FILE = ENGINE_DIR/out/state/ENV_CLUSTER.tfstate
  - echo all the variable before executing for logging & clarity
  - then render tfvars file
  - then run terraform
    - tf init -input=false -reconfigure -backend-config="path=$STATE_FILE"
    - tf $CMD -input=false -var-file ...

7. how does bootstrapping work? I'm not sure, since the golden policy should exist on its own, and cluster policy just logical have the same config, but in reality it is a separate instance. You also miss the full instructions to run with bootstrapping in container-vulnerability-exemption-tf/README.md or container-vulnerability-exemption/README.md

Fix as per improvements points, 

update docs: project_metadata/9_project_summary.md, container-vulnerability-exemption-tf/README.md or container-vulnerability-exemption/README.md as per improvements

Make sure all testing pass

This is production grade project understood?

After complete, move project_metadata/improvements.md to project_metadata/history/improvements.md
