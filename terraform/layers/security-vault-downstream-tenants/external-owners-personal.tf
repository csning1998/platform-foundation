
locals {
  _external_owners_personal = {
    "second-brain" = {
      services   = ["second-brain-app", "second-brain-db"],
      cidr_index = { first = 183, last = 186 }
    }
  }
}
